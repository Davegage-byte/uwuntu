#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="Uwuntu Image Manager"
APP_VERSION="1.24"

ROOT_HELPER="/usr/local/libexec/uwuntu-image-manager-root"
SUDOERS_FILE="/etc/sudoers.d/uwuntu-image-manager"

# ------------------------------------------------------------
# Benutzer ermitteln
# ------------------------------------------------------------
INSTALL_MODE="${1:-}"

if [[ "$INSTALL_MODE" == "--root-install" || "$INSTALL_MODE" == "--root-update" ]]; then
    REAL_USER="${2:-}"
    REAL_HOME="${3:-}"

    [[ -n "$REAL_USER" && -n "$REAL_HOME" ]] || {
        echo "Benutzerinformationen fehlen."
        exit 2
    }

    [[ "$REAL_USER" =~ ^[A-Za-z0-9._-]+$ ]] || {
        echo "Ungültiger Benutzername."
        exit 3
    }

    ROOT_MODE=1
else
    ROOT_MODE=0
    REAL_USER="${SUDO_USER:-$USER}"
    REAL_HOME="$HOME"
fi

# ============================================================
# ROOT-INSTALLATION
# ============================================================
if [[ "$ROOT_MODE" -eq 1 ]]; then
    export DEBIAN_FRONTEND=noninteractive

    REQUIRED_PACKAGES=(
        python3
        python3-gi
        gir1.2-gtk-4.0
        partclone
        zstd
        dosfstools
        e2fsprogs
        fio
        parted
        util-linux
        udisks2
        xdg-utils
        xdg-user-dirs
        desktop-file-utils
        libglib2.0-bin
        dbus-daemon
        tar
        coreutils
    )

    if [[ "$INSTALL_MODE" == "--root-install" ]]; then
        apt-get update
        apt-get install -y "${REQUIRED_PACKAGES[@]}"
    else
        if ! apt-get install -y "${REQUIRED_PACKAGES[@]}"; then
            apt-get update
            apt-get install -y "${REQUIRED_PACKAGES[@]}"
        fi
    fi

    # --------------------------------------------------------
    # Imaging-Station: GNOME-Automount deaktivieren
    # --------------------------------------------------------
    # Der Image Manager arbeitet direkt auf den Blockgeräten. Automatisches
    # Einhängen durch GNOME/GVFS kann dabei mit wipefs, fsck und parallelen
    # Restores kollidieren. Deshalb wird der Desktop für den realen Benutzer
    # gezielt auf manuelles Mounten gestellt.
    run_user_gsettings() {
        local user_uid user_runtime user_bus
        user_uid="$(id -u "$REAL_USER")"
        user_runtime="/run/user/$user_uid"
        user_bus="$user_runtime/bus"

        if [[ -S "$user_bus" ]]; then
            if runuser -u "$REAL_USER" -- env \
                HOME="$REAL_HOME" \
                USER="$REAL_USER" \
                LOGNAME="$REAL_USER" \
                XDG_RUNTIME_DIR="$user_runtime" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=$user_bus" \
                gsettings "$@"; then
                return 0
            fi
        fi

        # Fallback für Installation/Update ohne erreichbaren Desktop-Bus.
        # Die Werte werden trotzdem dauerhaft in der dconf-Datenbank des
        # realen Benutzers gespeichert.
        runuser -u "$REAL_USER" -- env \
            HOME="$REAL_HOME" \
            USER="$REAL_USER" \
            LOGNAME="$REAL_USER" \
            dbus-run-session -- gsettings "$@"
    }

    MEDIA_SCHEMA="org.gnome.desktop.media-handling"

    run_user_gsettings set "$MEDIA_SCHEMA" automount false
    run_user_gsettings set "$MEDIA_SCHEMA" automount-open false
    run_user_gsettings set "$MEDIA_SCHEMA" autorun-never true

    MEDIA_AUTOMOUNT="$(run_user_gsettings get "$MEDIA_SCHEMA" automount)"
    MEDIA_AUTOMOUNT_OPEN="$(run_user_gsettings get "$MEDIA_SCHEMA" automount-open)"
    MEDIA_AUTORUN_NEVER="$(run_user_gsettings get "$MEDIA_SCHEMA" autorun-never)"

    if [[ "$MEDIA_AUTOMOUNT" != "false" \
        || "$MEDIA_AUTOMOUNT_OPEN" != "false" \
        || "$MEDIA_AUTORUN_NEVER" != "true" ]]; then
        echo "GNOME-Automount konnte nicht korrekt konfiguriert werden."
        echo "automount=$MEDIA_AUTOMOUNT"
        echo "automount-open=$MEDIA_AUTOMOUNT_OPEN"
        echo "autorun-never=$MEDIA_AUTORUN_NEVER"
        exit 11
    fi

    echo "GNOME-Automount für $REAL_USER deaktiviert: false / false / true"

    mkdir -p /usr/local/libexec

    cat > "$ROOT_HELPER" <<'PYROOT'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import base64
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
import pwd
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

APP_VERSION = "1.24"
FORMAT_VERSION = "uwuntu-image-v3"
SUPPORTED_FORMAT_VERSIONS = {"uwuntu-image-v1", "uwuntu-image-v2", FORMAT_VERSION}

UPDATE_API_URL = (
    "https://api.github.com/repos/"
    "Davegage-byte/uwuntu/contents/"
    "Uwuntu%20Image%20Manager.sh?ref=main"
)
UPDATE_RAW_URL = (
    "https://raw.githubusercontent.com/"
    "Davegage-byte/uwuntu/main/"
    "Uwuntu%20Image%20Manager.sh"
)
MAX_UPDATE_BYTES = 4 * 1024 * 1024

MIB = 1024 * 1024

# Maximal weiterhin 29 GiB verwenden. Kleinere handelsübliche
# "32-GB"-Sticks dürfen aber real deutlich weniger GiB besitzen.
# Deshalb wird beim Restore automatisch auf die echte Zielgröße
# minus Reserve zurückgegangen.
RESTORE_MAX_TOTAL_MIB = 29 * 1024
RESTORE_END_RESERVE_MIB = 128

CHUNK = 4 * 1024 * 1024
BENCHMARK_RANDOM_SECONDS = 8
BENCHMARK_RANDOM_SIZE = 512 * MIB


# ============================================================
# Benutzerpfade / Logging
# ============================================================

def real_user():
    name = os.environ.get("SUDO_USER") or ""
    if not name or name == "root":
        # Aufruf läuft regulär per sudo aus dem Frontend.
        uid = int(os.environ.get("SUDO_UID") or 0)
        if uid:
            return pwd.getpwuid(uid).pw_name
        raise RuntimeError("Aufrufender Benutzer konnte nicht ermittelt werden.")
    return name


USER = real_user()
PW = pwd.getpwnam(USER)
HOME = Path(PW.pw_dir)
IMAGE_DIR = HOME / "Uwuntu-Images"
STATE_DIR = HOME / ".local/state/uwuntu-image-manager"
LOG_FILE = STATE_DIR / "manager.log"

IMAGE_DIR.mkdir(parents=True, exist_ok=True)
STATE_DIR.mkdir(parents=True, exist_ok=True)


def chown_user(path):
    try:
        os.chown(path, PW.pw_uid, PW.pw_gid)
    except Exception:
        pass


chown_user(IMAGE_DIR)
chown_user(STATE_DIR)


def log(message):
    line = f"{dt.datetime.now().astimezone().isoformat(timespec='seconds')}  {message}\n"
    try:
        with LOG_FILE.open("a", encoding="utf-8") as handle:
            handle.write(line)
        chown_user(LOG_FILE)
    except Exception:
        pass


def emit(event_type, **data):
    payload = {"type": event_type, **data}
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def fail(message, code=1):
    log(f"FEHLER: {message}")
    emit("error", message=message)
    raise SystemExit(code)


# ============================================================
# Fortschritt
# ============================================================

class Progress:
    def __init__(self, stage, stage_index, stage_count, total, direction):
        self.stage = stage
        self.stage_index = stage_index
        self.stage_count = stage_count
        self.total = max(1, int(total))
        self.direction = direction
        self.start = time.monotonic()
        self.prev_t = self.start
        self.prev_b = 0
        self.last_emit = 0.0
        self.rate_smooth = 0.0

        emit(
            "stage",
            stage=stage,
            stage_index=stage_index,
            stage_count=stage_count,
            direction=direction,
        )

    def update(self, done, force=False):
        done = max(0, int(done))
        now = time.monotonic()

        if not force and now - self.last_emit < 0.35:
            return

        dt_s = max(0.001, now - self.prev_t)
        delta = max(0, done - self.prev_b)
        rate = delta / dt_s

        if self.rate_smooth <= 0:
            self.rate_smooth = rate
        else:
            self.rate_smooth = 0.72 * self.rate_smooth + 0.28 * rate

        fraction = min(0.995, done / self.total)
        remaining = max(0, self.total - done)
        eta = remaining / self.rate_smooth if self.rate_smooth > 1 else None

        emit(
            "progress",
            stage=self.stage,
            stage_index=self.stage_index,
            stage_count=self.stage_count,
            fraction=fraction,
            done=done,
            total=self.total,
            rate_bps=self.rate_smooth,
            eta_seconds=eta,
            direction=self.direction,
        )

        self.prev_t = now
        self.prev_b = done
        self.last_emit = now

    def finish(self, done=None):
        if done is None:
            done = self.total
        emit(
            "progress",
            stage=self.stage,
            stage_index=self.stage_index,
            stage_count=self.stage_count,
            fraction=1.0,
            done=int(done),
            total=max(int(done), self.total),
            rate_bps=self.rate_smooth,
            eta_seconds=0,
            direction=self.direction,
        )


# ============================================================
# System / Datenträger
# ============================================================

def run(args, check=True, capture=False, timeout=None):
    log("CMD: " + " ".join(map(str, args)))

    kwargs = {
        "text": True,
        "timeout": timeout,
    }

    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE
    else:
        log_handle = LOG_FILE.open("a", encoding="utf-8")
        kwargs["stdout"] = log_handle
        kwargs["stderr"] = log_handle

    try:
        result = subprocess.run(args, **kwargs)
    finally:
        if not capture:
            log_handle.close()

    if check and result.returncode != 0:
        detail = ""
        if capture:
            detail = (result.stderr or result.stdout or "").strip()
        raise RuntimeError(
            f"Befehl fehlgeschlagen ({result.returncode}): "
            + " ".join(map(str, args))
            + (f"\n{detail}" if detail else "")
        )

    return result


def output(args, timeout=10):
    return run(args, capture=True, timeout=timeout).stdout.strip()


def base_disk_for_source(source):
    if not source or not source.startswith("/dev/"):
        return ""

    current = source

    for _ in range(12):
        try:
            parent = output(
                ["lsblk", "-ndo", "PKNAME", current],
                timeout=3,
            ).splitlines()
        except Exception:
            break

        parent = parent[0].strip() if parent else ""
        if not parent:
            break

        current = "/dev/" + parent

    try:
        typ = output(["lsblk", "-ndo", "TYPE", current], timeout=3)
    except Exception:
        return ""

    return current if typ.strip() == "disk" else ""


def system_disks():
    found = set()

    for mountpoint in ("/", "/boot", "/boot/efi", "/cdrom"):
        try:
            source = output(
                ["findmnt", "-rn", "-o", "SOURCE", mountpoint],
                timeout=3,
            ).splitlines()
        except Exception:
            continue

        if not source:
            continue

        disk = base_disk_for_source(source[0].strip())
        if disk:
            found.add(disk)

    return found


def disk_for_path(path):
    try:
        source = output(
            ["findmnt", "-T", str(path), "-rn", "-o", "SOURCE"],
            timeout=3,
        ).splitlines()
    except Exception:
        return ""

    if not source:
        return ""

    return base_disk_for_source(source[0].strip())


def validate_disk(disk):
    if not re.fullmatch(r"/dev/[A-Za-z0-9._+-]+", disk or ""):
        fail(f"Ungültiger Datenträger: {disk}")

    p = Path(disk)
    if not p.exists():
        fail(f"Datenträger nicht gefunden: {disk}")

    try:
        typ = output(["lsblk", "-ndo", "TYPE", disk], timeout=3)
    except Exception:
        fail(f"Datenträger konnte nicht geprüft werden: {disk}")

    if typ.strip() != "disk":
        fail(f"Auswahl ist kein kompletter Datenträger: {disk}")

    if disk in system_disks():
        fail(
            "Der laufende Ubuntu-Systemdatenträger ist geschützt und "
            "kann mit diesem Tool nicht als Quelle/Ziel verwendet werden."
        )


def part_path(disk, number):
    if re.search(r"\d$", disk):
        return f"{disk}p{number}"
    return f"{disk}{number}"


def wait_partition(path, timeout=12):
    end = time.monotonic() + timeout

    while time.monotonic() < end:
        if Path(path).exists():
            return
        run(["udevadm", "settle"], check=False)
        time.sleep(0.4)

    fail(f"Partition wurde nicht angelegt/erkannt: {path}")


def _disk_partitions(disk):
    try:
        rows = output(
            ["lsblk", "-rnpo", "PATH,TYPE", disk],
            timeout=10,
        ).splitlines()
    except Exception as exc:
        log(f"UNMOUNT: Partitionen für {disk} konnten nicht gelesen werden: {exc}")
        return []

    partitions = []
    for row in rows:
        parts = row.split()
        if len(parts) >= 2 and parts[1] == "part":
            partitions.append(parts[0])
    return partitions


def _partition_mounts(part):
    try:
        return output(
            ["findmnt", "-rn", "-S", part, "-o", "TARGET"],
            timeout=5,
        ).splitlines()
    except Exception:
        return []


def _best_effort(args, timeout=10):
    try:
        return run(args, check=False, timeout=timeout)
    except Exception as exc:
        log(
            "BEST-EFFORT FEHLER: "
            + " ".join(map(str, args))
            + f": {exc}"
        )
        return None


def unmount_disk(disk, retries=5, lazy_fallback=False):
    """Alle Partitionen eines Datenträgers robust aushängen.

    Wichtig: Es wird über den Gerätepfad ausgehängt und nicht über
    den von findmnt escaped ausgegebenen Mountpoint. Dadurch sind
    Mountpunkte mit Leerzeichen (\x20) unkritisch.
    """
    partitions = _disk_partitions(disk)
    if not partitions:
        return True

    retries = max(1, int(retries))

    for attempt in range(1, retries + 1):
        for part in reversed(partitions):
            if not _partition_mounts(part):
                continue

            log(f"UNMOUNT: {part} Versuch {attempt}/{retries}")
            _best_effort(
                ["udisksctl", "unmount", "-b", part],
                timeout=10,
            )
            _best_effort(["umount", part], timeout=10)

        _best_effort(["udevadm", "settle"], timeout=15)

        remaining = [
            part for part in partitions if _partition_mounts(part)
        ]
        if not remaining:
            return True

        time.sleep(min(0.25 * attempt, 1.0))

    if lazy_fallback:
        for part in reversed(partitions):
            if _partition_mounts(part):
                log(f"UNMOUNT-LAZY: {part}")
                _best_effort(["umount", "-l", part], timeout=10)

        _best_effort(["udevadm", "settle"], timeout=15)
        time.sleep(0.35)

    remaining = [
        part for part in partitions if _partition_mounts(part)
    ]
    if remaining:
        log(
            f"UNMOUNT: {disk} weiterhin belegt: "
            + ", ".join(remaining)
        )
        return False

    return True


def wipe_disk_for_restore(disk, attempts=8):
    """wipefs gegen Desktop-/UDisks-Automount-Races absichern."""
    last_detail = ""

    for attempt in range(1, attempts + 1):
        unmount_disk(
            disk,
            retries=3,
            lazy_fallback=attempt >= 4,
        )
        _best_effort(["sync"], timeout=20)
        _best_effort(["udevadm", "settle"], timeout=15)

        try:
            result = run(
                ["wipefs", "-a", disk],
                check=False,
                capture=True,
                timeout=15,
            )
            if result.returncode == 0:
                if attempt > 1:
                    log(f"WIPEFS: {disk} nach {attempt} Versuchen frei")
                return

            last_detail = (
                (result.stderr or result.stdout or "").strip()
            )
        except subprocess.TimeoutExpired as exc:
            last_detail = f"Timeout nach {exc.timeout} s"
        except Exception as exc:
            last_detail = str(exc)

        log(
            f"WIPEFS RETRY {attempt}/{attempts}: {disk}: "
            f"{last_detail or 'Gerät noch belegt'}"
        )
        time.sleep(min(0.35 * attempt, 1.5))

    raise RuntimeError(
        f"Der Zielstick {disk} blieb trotz mehrfacher "
        "Aushängeversuche belegt. "
        f"Letzte wipefs-Meldung: {last_detail or 'unbekannt'}"
    )


def disk_info(disk):
    result = run(
        ["lsblk", "-J", "-b", "-d", "-o", "PATH,SIZE,MODEL,SERIAL,TYPE,RM,TRAN", disk],
        capture=True,
        timeout=5,
    )

    data = json.loads(result.stdout)
    dev = (data.get("blockdevices") or [{}])[0]

    return {
        "path": dev.get("path") or disk,
        "size_bytes": int(dev.get("size") or 0),
        "model": " ".join((dev.get("model") or "Unbekannt").split()),
        "serial": (dev.get("serial") or "").strip(),
        "transport": (dev.get("tran") or "").strip(),
        "removable": bool(int(dev.get("rm") or 0)),
    }


def fs_info(part):
    def blk(field):
        try:
            return output(
                ["blkid", "-s", field, "-o", "value", part],
                timeout=3,
            ).strip()
        except Exception:
            return ""

    try:
        size = int(output(["lsblk", "-bno", "SIZE", part], timeout=3))
    except Exception:
        size = 0

    return {
        "fstype": blk("TYPE").lower(),
        "label": blk("LABEL"),
        "uuid": blk("UUID"),
        "size_bytes": size,
    }


# ============================================================
# USB-Benchmark
# ============================================================

def fio_random_benchmark(disk, rw, stage_index, direction):
    if rw not in {"randread", "randwrite"}:
        raise RuntimeError(f"Ungültiger fio-Modus: {rw}")

    progress = Progress(
        f"USB-Benchmark · 4K Random {direction.lower()}",
        stage_index,
        4,
        BENCHMARK_RANDOM_SECONDS,
        direction,
    )

    command = [
        "fio",
        f"--name=uwuntu-4k-{rw}",
        f"--filename={disk}",
        f"--rw={rw}",
        "--bs=4k",
        "--direct=1",
        "--iodepth=1",
        f"--runtime={BENCHMARK_RANDOM_SECONDS}",
        "--time_based",
        f"--size={BENCHMARK_RANDOM_SIZE}",
        "--offset=0",
        "--numjobs=1",
        "--group_reporting",
        "--randrepeat=0",
        "--norandommap=1",
        "--output-format=json",
        "--eta=never",
    ]

    log("CMD: " + " ".join(command))
    started = time.monotonic()

    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=BENCHMARK_RANDOM_SECONDS + 20,
    )

    elapsed = max(0.001, time.monotonic() - started)

    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise RuntimeError(
            f"fio 4K Random {direction.lower()} fehlgeschlagen "
            f"({result.returncode})."
            + (f"\n{detail}" if detail else "")
        )

    try:
        payload = json.loads(result.stdout)
        job = (payload.get("jobs") or [])[0]
        stats = job["read" if rw == "randread" else "write"]
        iops = float(stats.get("iops") or 0.0)
        bw_bytes = float(stats.get("bw_bytes") or 0.0)
        latency = stats.get("clat_ns") or stats.get("lat_ns") or {}
        latency_ms = float(latency.get("mean") or 0.0) / 1_000_000
    except Exception as exc:
        raise RuntimeError(
            "fio-Ergebnis konnte nicht ausgewertet werden."
        ) from exc

    if iops <= 0 or bw_bytes <= 0:
        raise RuntimeError(
            f"fio 4K Random {direction.lower()} lieferte "
            "keine gültigen Leistungswerte."
        )

    progress.finish(BENCHMARK_RANDOM_SECONDS)

    return {
        "iops": iops,
        "mbps": bw_bytes / 1_000_000,
        "latency_ms": latency_ms,
        "seconds": elapsed,
    }


def benchmark(args):
    disk = args.disk
    validate_disk(disk)

    total_bytes = 512 * MIB
    block_bytes = 32 * MIB
    info = disk_info(disk)

    transport = str(info.get("transport") or "").strip().lower()
    removable = bool(info.get("removable"))
    if transport != "usb" and not removable:
        fail(
            "Der USB-Benchmark ist aus Sicherheitsgründen nur für "
            "USB- oder Wechseldatenträger freigegeben."
        )

    if int(info.get("size_bytes") or 0) < total_bytes:
        fail("Der ausgewählte Datenträger ist kleiner als 512 MiB.")

    try:
        emit(
            "info",
            message=(
                f"USB-Benchmark: {info['model']} · {disk} · "
                "512 MiB sequenziell + 4K Random QD1"
            ),
        )

        unmount_disk(disk)
        run(["sync"], check=False)
        run(["blockdev", "--flushbufs", disk])

        # Nicht komprimierbares Testmuster. Die ersten 4 KiB bleiben Null,
        # damit keine zufällige gültige Partitionstabelle entsteht.
        pattern = b"\0" * 4096 + os.urandom(block_bytes - 4096)

        write_progress = Progress(
            "USB-Benchmark · 512 MiB schreiben",
            1,
            4,
            total_bytes,
            "SCHREIBEN",
        )

        write_started = time.monotonic()
        done = 0

        with open(disk, "r+b", buffering=0) as handle:
            while done < total_bytes:
                view = memoryview(pattern)
                while view:
                    written = handle.write(view)
                    if not written:
                        raise RuntimeError(
                            "USB-Benchmark konnte nicht weiter schreiben."
                        )
                    view = view[written:]
                done += block_bytes
                write_progress.update(done)

            handle.flush()
            os.fsync(handle.fileno())

        write_seconds = max(0.001, time.monotonic() - write_started)
        write_progress.finish(total_bytes)

        run(["sync"], check=False)
        run(["blockdev", "--flushbufs", disk])

        read_progress = Progress(
            "USB-Benchmark · 512 MiB lesen",
            2,
            4,
            total_bytes,
            "LESEN",
        )

        read_started = time.monotonic()
        done = 0

        with open(disk, "rb", buffering=0) as handle:
            while done < total_bytes:
                chunk = handle.read(block_bytes)
                if len(chunk) != block_bytes:
                    raise RuntimeError(
                        "USB-Benchmark konnte nicht 512 MiB vollständig lesen."
                    )
                if chunk != pattern:
                    raise RuntimeError(
                        "Die gelesenen Testdaten stimmen nicht mit den "
                        "geschriebenen Daten überein."
                    )
                done += len(chunk)
                read_progress.update(done)

        read_seconds = max(0.001, time.monotonic() - read_started)
        read_progress.finish(total_bytes)

        random_write = fio_random_benchmark(
            disk,
            "randwrite",
            3,
            "SCHREIBEN",
        )

        run(["sync"], check=False)
        run(["blockdev", "--flushbufs", disk])

        random_read = fio_random_benchmark(
            disk,
            "randread",
            4,
            "LESEN",
        )

        write_mbps = total_bytes / write_seconds / 1_000_000
        read_mbps = total_bytes / read_seconds / 1_000_000
        total_seconds = (
            write_seconds
            + read_seconds
            + random_write["seconds"]
            + random_read["seconds"]
        )

        write_text = f"{write_mbps:.1f}".replace(".", ",")
        read_text = f"{read_mbps:.1f}".replace(".", ",")
        random_write_iops_text = f"{random_write['iops']:.0f}".replace(".", ",")
        random_read_iops_text = f"{random_read['iops']:.0f}".replace(".", ",")
        random_write_mbps_text = f"{random_write['mbps']:.1f}".replace(".", ",")
        random_read_mbps_text = f"{random_read['mbps']:.1f}".replace(".", ",")
        random_write_latency_text = (
            f"{random_write['latency_ms']:.2f}".replace(".", ",")
        )
        random_read_latency_text = (
            f"{random_read['latency_ms']:.2f}".replace(".", ",")
        )
        write_time_text = f"{write_seconds:.1f}".replace(".", ",")
        read_time_text = f"{read_seconds:.1f}".replace(".", ",")
        total_time_text = f"{total_seconds:.1f}".replace(".", ",")

        log(
            "USB-BENCHMARK ERFOLGREICH: "
            f"{disk}; write={write_mbps:.2f}MB/s; "
            f"read={read_mbps:.2f}MB/s; "
            f"randwrite={random_write['iops']:.2f}IOPS/"
            f"{random_write['mbps']:.2f}MB/s; "
            f"randread={random_read['iops']:.2f}IOPS/"
            f"{random_read['mbps']:.2f}MB/s; "
            f"write_s={write_seconds:.2f}; read_s={read_seconds:.2f}"
        )

        run(["sync"], check=False)
        run(["blockdev", "--rereadpt", disk], check=False)
        run(["udevadm", "settle"], check=False)
        poweroff = run(
            ["udisksctl", "power-off", "-b", disk],
            check=False,
        )

        if poweroff.returncode == 0:
            finish_note = (
                "Der Stick wurde sicher ausgeworfen und kann entfernt werden."
            )
        else:
            finish_note = (
                "Der Stick ist synchronisiert und ausgehängt. "
                "Er kann jetzt entfernt werden."
            )

        emit(
            "success",
            message="USB-Benchmark abgeschlossen.",
            detail=(
                f"{info['model']} · {disk}\n\n"
                "SEQUENZIELL · 512 MiB\n"
                f"Schreiben: {write_text} MB/s\n"
                f"Lesen: {read_text} MB/s\n"
                f"Schreibzeit: {write_time_text} s\n"
                f"Lesezeit: {read_time_text} s\n\n"
                "4K RANDOM · QD1 · DIRECT I/O\n"
                f"Schreiben: {random_write_iops_text} IOPS · "
                f"{random_write_mbps_text} MB/s · "
                f"{random_write_latency_text} ms\n"
                f"Lesen: {random_read_iops_text} IOPS · "
                f"{random_read_mbps_text} MB/s · "
                f"{random_read_latency_text} ms\n"
                f"Je Random-Test: {BENCHMARK_RANDOM_SECONDS} s\n\n"
                f"Gesamt: {total_time_text} s\n\n"
                "Die ersten 512 MiB wurden für den Test überschrieben. "
                "Der Stick ist dadurch nicht mehr bootfähig und muss "
                "vor normaler Nutzung neu formatiert oder mit dem "
                "Uwuntu Image Manager wiederhergestellt werden.\n\n"
                + finish_note
            ),
        )

    except SystemExit:
        raise
    except Exception as exc:
        fail(f"USB-Benchmark fehlgeschlagen:\n{exc}")


# ============================================================
# Image
# ============================================================

def safe_image_path(path):
    p = Path(path).expanduser().resolve()
    root = IMAGE_DIR.resolve()

    try:
        p.relative_to(root)
    except Exception:
        fail(
            "Images dürfen nur aus dem Uwuntu-Image-Ordner verwendet werden:\n"
            f"{IMAGE_DIR}"
        )

    if p.suffix.lower() != ".uwuntu":
        fail("Die ausgewählte Datei ist kein .uwuntu-Image.")

    if not p.is_file():
        fail(f"Image wurde nicht gefunden: {p}")

    return p


def read_metadata(image):
    try:
        with tarfile.open(image, "r") as tf:
            member = tf.getmember("metadata.json")
            handle = tf.extractfile(member)
            if handle is None:
                raise RuntimeError("metadata.json fehlt")
            data = json.loads(handle.read().decode("utf-8"))
    except Exception as exc:
        fail(f"Image-Metadaten konnten nicht gelesen werden:\n{exc}")

    if data.get("format") not in SUPPORTED_FORMAT_VERSIONS:
        fail(
            "Dieses Image hat ein nicht unterstütztes Format.\n"
            f"Gefunden: {data.get('format', 'unbekannt')}"
        )

    return data


def read_member(image, name):
    with tarfile.open(image, "r") as tf:
        member = tf.getmember(name)
        handle = tf.extractfile(member)
        if handle is None:
            raise RuntimeError(f"{name} fehlt")
        return handle.read()


def hash_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(CHUNK)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def normalize_filename(value):
    value = re.sub(r"[^A-Za-z0-9._-]+", "_", value.strip())
    return value.strip("._-") or "Uwuntu"


# ============================================================
# Streaming-Helfer
# ============================================================

def stream_file_to_zstd(source, target, total, progress):
    log_handle = LOG_FILE.open("a", encoding="utf-8")
    proc = subprocess.Popen(
        ["zstd", "-T0", "-3", "-q", "-o", str(target)],
        stdin=subprocess.PIPE,
        stdout=log_handle,
        stderr=log_handle,
    )

    done = 0

    try:
        with open(source, "rb", buffering=0) as src:
            while True:
                chunk = src.read(CHUNK)
                if not chunk:
                    break
                proc.stdin.write(chunk)
                done += len(chunk)
                progress.update(done)

        proc.stdin.close()
        rc = proc.wait()
    finally:
        log_handle.close()

    if rc != 0:
        raise RuntimeError("zstd-Komprimierung fehlgeschlagen.")

    progress.finish(done)
    return done



def stream_partclone_to_zstd(source, target, total, progress):
    log_handle = LOG_FILE.open("a", encoding="utf-8")
    partclone_proc = subprocess.Popen(
        [
            "partclone.vfat",
            "-c",
            "-s",
            str(source),
            "-o",
            "-",
            "-q",
        ],
        stdout=subprocess.PIPE,
        stderr=log_handle,
    )
    zstd_proc = subprocess.Popen(
        ["zstd", "-T0", "-3", "-q", "-o", str(target)],
        stdin=subprocess.PIPE,
        stdout=log_handle,
        stderr=log_handle,
    )

    done = 0
    partclone_rc = None
    zstd_rc = None
    pipeline_error = None

    try:
        while True:
            chunk = partclone_proc.stdout.read(CHUNK)
            if not chunk:
                break

            zstd_proc.stdin.write(chunk)
            done += len(chunk)
            progress.update(done)

        zstd_proc.stdin.close()
        partclone_rc = partclone_proc.wait()
        zstd_rc = zstd_proc.wait()
    except Exception as exc:
        pipeline_error = exc
        try:
            zstd_proc.stdin.close()
        except Exception:
            pass

        for proc in (partclone_proc, zstd_proc):
            try:
                if proc.poll() is None:
                    proc.terminate()
            except Exception:
                pass

        for proc in (partclone_proc, zstd_proc):
            try:
                proc.wait(timeout=5)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
    finally:
        try:
            partclone_proc.stdout.close()
        except Exception:
            pass
        log_handle.close()

    if pipeline_error is not None:
        raise RuntimeError(
            f"Partclone-Backup-Pipeline fehlgeschlagen: {pipeline_error}"
        ) from pipeline_error
    if partclone_rc != 0:
        raise RuntimeError("Partclone-Sicherung der Boot-Partition fehlgeschlagen.")
    if zstd_rc != 0:
        raise RuntimeError("zstd-Komprimierung der Boot-Partition fehlgeschlagen.")

    progress.finish(done)
    return done


def ext_partclone_program(fstype):
    fstype = str(fstype or "").lower()
    if fstype == "ext3":
        return "partclone.ext3"
    if fstype == "ext4":
        return "partclone.ext4"
    raise RuntimeError(
        f"Nicht unterstütztes Persistenz-Dateisystem: {fstype or 'unbekannt'}"
    )


def ext_filesystem_size_bytes(path):
    info = output(
        ["env", "LC_ALL=C", "dumpe2fs", "-h", str(path)],
        timeout=30,
    )

    block_count = None
    block_size = None

    for line in info.splitlines():
        if line.startswith("Block count:"):
            block_count = int(line.split(":", 1)[1].strip())
        elif line.startswith("Block size:"):
            block_size = int(line.split(":", 1)[1].strip())

    if not block_count or not block_size:
        raise RuntimeError(
            "Größe des kompakten Persistenz-Dateisystems konnte nicht "
            "ermittelt werden."
        )

    return block_count * block_size


def prepare_compact_ext_image(source, target, source_size, progress):
    target.unlink(missing_ok=True)

    # Rohes ext-Abbild als sparse Datei: unbenutzte Blöcke werden nicht
    # physisch kopiert. Der Master-Stick selbst bleibt unverändert.
    run(["e2image", "-rap", str(source), str(target)])
    progress.update(1, force=True)

    # Ein Vollcheck bleibt vor dem Verkleinern notwendig. Danach wird die
    # temporäre Kopie exakt auf die Minimalgröße des Dateisystems gekürzt.
    ext_check = run(["e2fsck", "-fy", str(target)], check=False)
    if ext_check.returncode not in (0, 1):
        raise RuntimeError(
            "Persistenz-Dateisystemprüfung vor dem Verkleinern "
            f"fehlgeschlagen (e2fsck Status {ext_check.returncode})."
        )
    run(["resize2fs", "-M", str(target)])
    compact_size = ext_filesystem_size_bytes(target)
    progress.update(2, force=True)

    if compact_size <= 0 or compact_size > int(source_size):
        raise RuntimeError(
  "Kompaktes Persistenz-Dateisystem hat eine ungültige Größe."
        )

    # Freier Platz wird erst beim Restore auf der echten Zielpartition
    # erzeugt. Damit entfallen hier der bisherige +256-MiB-Grow und die
    # zweite erzwungene Vollprüfung.
    with open(target, "r+b") as handle:
        handle.truncate(compact_size)

    ext_check = run(["e2fsck", "-p", str(target)], check=False)
    if ext_check.returncode not in (0, 1):
        raise RuntimeError(
  "Das kompakte Persistenz-Dateisystem konnte nach dem "
  "Verkleinern nicht sauber geprüft werden."
        )

    actual_size = ext_filesystem_size_bytes(target)
    if actual_size > compact_size:
        raise RuntimeError(
  "Das vorbereitete Persistenz-Dateisystem überschreitet seine "
  "kompakte Zielgröße."
        )

    progress.finish(3)
    return compact_size

def stream_ext_partclone_to_zstd(
    source,
    target,
    total,
    progress,
    fstype,
):
    program = ext_partclone_program(fstype)
    log_handle = LOG_FILE.open("a", encoding="utf-8")
    partclone_proc = subprocess.Popen(
        [program, "-c", "-s", str(source), "-o", "-", "-q"],
        stdout=subprocess.PIPE,
        stderr=log_handle,
    )
    zstd_proc = subprocess.Popen(
        ["zstd", "-T0", "-3", "-q", "-o", str(target)],
        stdin=subprocess.PIPE,
        stdout=log_handle,
        stderr=log_handle,
    )

    done = 0
    partclone_rc = None
    zstd_rc = None
    pipeline_error = None

    try:
        while True:
            chunk = partclone_proc.stdout.read(CHUNK)
            if not chunk:
                break

            zstd_proc.stdin.write(chunk)
            done += len(chunk)
            progress.update(done)

        zstd_proc.stdin.close()
        partclone_rc = partclone_proc.wait()
        zstd_rc = zstd_proc.wait()
    except Exception as exc:
        pipeline_error = exc
        try:
            zstd_proc.stdin.close()
        except Exception:
            pass

        for proc in (partclone_proc, zstd_proc):
            try:
                if proc.poll() is None:
                    proc.terminate()
            except Exception:
                pass

        for proc in (partclone_proc, zstd_proc):
            try:
                proc.wait(timeout=5)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
    finally:
        try:
            partclone_proc.stdout.close()
        except Exception:
            pass
        log_handle.close()

    if pipeline_error is not None:
        raise RuntimeError(
            f"Partclone-Persistenz-Backup fehlgeschlagen: {pipeline_error}"
        ) from pipeline_error
    if partclone_rc != 0:
        raise RuntimeError("Partclone-Sicherung der Persistenz ist fehlgeschlagen.")
    if zstd_rc != 0:
        raise RuntimeError("zstd-Komprimierung der Persistenz ist fehlgeschlagen.")

    progress.finish(done)
    return done


def stream_tar_to_zstd(mountpoint, target, estimate, progress):
    log_handle = LOG_FILE.open("a", encoding="utf-8")

    tar_proc = subprocess.Popen(
        [
            "tar",
            "--numeric-owner",
            "--xattrs",
            "--acls",
            "--one-file-system",
            "-C",
            str(mountpoint),
            "-cpf",
            "-",
            ".",
        ],
        stdout=subprocess.PIPE,
        stderr=log_handle,
    )

    zstd_proc = subprocess.Popen(
        ["zstd", "-T0", "-3", "-q", "-o", str(target)],
        stdin=subprocess.PIPE,
        stdout=log_handle,
        stderr=log_handle,
    )

    done = 0

    try:
        while True:
            chunk = tar_proc.stdout.read(CHUNK)
            if not chunk:
                break

            zstd_proc.stdin.write(chunk)
            done += len(chunk)
            progress.update(done)

        zstd_proc.stdin.close()
        tar_rc = tar_proc.wait()
        zstd_rc = zstd_proc.wait()
    finally:
        log_handle.close()

    if tar_rc != 0:
        raise RuntimeError("tar-Backup der Persistenz ist fehlgeschlagen.")
    if zstd_rc != 0:
        raise RuntimeError("zstd-Komprimierung der Persistenz ist fehlgeschlagen.")

    progress.finish(done)
    return done


def package_image(temp_dir, final_path, progress):
    files = [
        "metadata.json",
        "mbr_bootcode.bin",
        "root.fat.partclone.zst",
        "persistence.ext.partclone.zst",
    ]

    expected = sum((temp_dir / name).stat().st_size for name in files)
    partial = final_path.with_suffix(final_path.suffix + ".partial")

    partial.unlink(missing_ok=True)

    log_handle = LOG_FILE.open("a", encoding="utf-8")
    proc = subprocess.Popen(
        ["tar", "-cf", str(partial), "-C", str(temp_dir), *files],
        stdout=log_handle,
        stderr=log_handle,
    )

    previous = 0

    try:
        while proc.poll() is None:
            try:
                current = partial.stat().st_size
            except Exception:
                current = previous
            previous = current
            progress.update(min(current, expected))
            time.sleep(0.35)

        rc = proc.wait()
    finally:
        log_handle.close()

    if rc != 0:
        partial.unlink(missing_ok=True)
        raise RuntimeError("Das .uwuntu-Image konnte nicht verpackt werden.")

    progress.finish(expected)
    partial.replace(final_path)
    chown_user(final_path)


def feed_member_to_zstd(image, member_name, expected_hash=None):
    tf = tarfile.open(image, "r")
    member = tf.getmember(member_name)
    member_file = tf.extractfile(member)

    if member_file is None:
        tf.close()
        raise RuntimeError(f"{member_name} fehlt im Image.")

    log_handle = LOG_FILE.open("a", encoding="utf-8")
    zstd = subprocess.Popen(
        ["zstd", "-q", "-dc"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=log_handle,
    )

    result = {
        "hash": "",
        "error": None,
    }

    def feeder():
        h = hashlib.sha256()
        try:
            while True:
                chunk = member_file.read(CHUNK)
                if not chunk:
                    break
                h.update(chunk)
                zstd.stdin.write(chunk)

            zstd.stdin.close()
            result["hash"] = h.hexdigest()
        except Exception as exc:
            result["error"] = exc
            try:
                zstd.stdin.close()
            except Exception:
                pass
        finally:
            member_file.close()
            tf.close()

    thread = threading.Thread(target=feeder, daemon=True)
    thread.start()

    return zstd, thread, result, log_handle


def check_member_hash(result, expected):
    if result.get("error"):
        raise result["error"]

    if expected and result.get("hash") != expected:
        raise RuntimeError("Image-Prüfsumme stimmt nicht.")


# ============================================================
# Backup
# ============================================================

def backup(args):
    disk = args.disk
    validate_disk(disk)

    if disk_for_path(IMAGE_DIR) == disk:
        fail("Der Image-Ordner liegt auf dem ausgewählten Quellstick.")

    p1 = part_path(disk, 1)
    p2 = part_path(disk, 2)

    if not Path(p1).exists() or not Path(p2).exists():
        fail(
            "Der Uwuntu-Stick muss mindestens Partition 1 (FAT32) "
            "und Partition 2 (ext4) besitzen."
        )

    p1_info = fs_info(p1)
    p2_info = fs_info(p2)

    if p1_info["fstype"] not in {"vfat", "fat", "fat32"}:
        fail(
            "Partition 1 des ausgewählten Sticks ist nicht FAT32/VFAT.\n"
            f"Gefunden: {p1_info['fstype'] or 'unbekannt'}"
        )

    if p2_info["fstype"] not in {"ext3", "ext4"}:
        fail(
            "Partition 2 des ausgewählten Sticks ist weder ext3 noch ext4.\n"
            f"Gefunden: {p2_info['fstype'] or 'unbekannt'}"
        )

    source = disk_info(disk)

    emit(
        "info",
        message=(
            f"Quelle: {source['model']} · {source['path']} · "
            f"{source['size_bytes']} Bytes"
        ),
    )

    unmount_disk(disk)

    stamp = dt.datetime.now().astimezone().strftime("%Y-%m-%d_%H-%M-%S")
    model_part = normalize_filename(source["model"])[:30]
    final = IMAGE_DIR / f"Uwuntu_{stamp}_{model_part}.uwuntu"

    temp_dir = Path(
        tempfile.mkdtemp(
            prefix=".uwuntu-build-",
            dir=str(IMAGE_DIR),
        )
    )

    chown_user(temp_dir)

    mount_dir = Path(tempfile.mkdtemp(prefix="uwuntu-persist-src-", dir="/mnt"))

    try:
        # ----------------------------------------------------
        # 1/4 Boot/FAT
        # ----------------------------------------------------
        root_zst = temp_dir / "root.fat.partclone.zst"

        p = Progress(
            "Boot-Partition sichern",
            1,
            5,
            p1_info["size_bytes"],
            "LESEN",
        )

        root_stream_bytes = stream_partclone_to_zstd(
            p1,
            root_zst,
            p1_info["size_bytes"],
            p,
        )

        # ----------------------------------------------------
        # 2/5 Persistenz-Dateisystem kompakt vorbereiten
        # ----------------------------------------------------
        compact_ext = temp_dir / "persistence.compact.ext"

        p = Progress(
            "Persistenz für Schnell-Restore vorbereiten",
            2,
            5,
            3,
            "VORBEREITEN",
        )

        compact_size_bytes = prepare_compact_ext_image(
            p2,
            compact_ext,
            p2_info["size_bytes"],
            p,
        )

        # ----------------------------------------------------
        # 3/5 Persistenz blockweise sichern
        # ----------------------------------------------------
        persistence_zst = temp_dir / "persistence.ext.partclone.zst"

        p = Progress(
            "Persistenz blockweise sichern",
            3,
            5,
            compact_size_bytes,
            "LESEN",
        )

        persistence_stream_bytes = stream_ext_partclone_to_zstd(
            compact_ext,
            persistence_zst,
            compact_size_bytes,
            p,
            p2_info["fstype"],
        )

        compact_ext.unlink(missing_ok=True)

        # ----------------------------------------------------
        # 4/5 Metadaten / Prüfsummen
        # ----------------------------------------------------
        p = Progress(
            "Image prüfen und vorbereiten",
            4,
            5,
            3,
            "PRÜFEN",
        )

        with open(disk, "rb", buffering=0) as handle:
            mbr = handle.read(440)

        mbr_path = temp_dir / "mbr_bootcode.bin"
        mbr_path.write_bytes(mbr)

        p.update(1, force=True)

        checksums = {
            "mbr_bootcode.bin": hash_file(mbr_path),
            "root.fat.partclone.zst": hash_file(root_zst),
            "persistence.ext.partclone.zst": hash_file(persistence_zst),
        }

        p.update(2, force=True)

        metadata = {
            "format": FORMAT_VERSION,
            "tool_version": APP_VERSION,
            "created": dt.datetime.now().astimezone().isoformat(
                timespec="seconds"
            ),
            "source": source,
            "partition1": {
                **p1_info,
                "backup": "root.fat.partclone.zst",
                "backup_method": "partclone-vfat",
                "partclone_stream_bytes": root_stream_bytes,
            },
            "partition2": {
                **p2_info,
                "backup": "persistence.ext.partclone.zst",
                "backup_method": f"partclone-{p2_info['fstype']}",
                "partclone_stream_bytes": persistence_stream_bytes,
                "compact_size_bytes": compact_size_bytes,
            },
            "restore_max_total_mib": RESTORE_MAX_TOTAL_MIB,
            "restore_end_reserve_mib": RESTORE_END_RESERVE_MIB,
            "checksums": checksums,
        }

        meta_path = temp_dir / "metadata.json"
        meta_path.write_text(
            json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

        p.finish(3)

        # ----------------------------------------------------
        # 5/5 Einzelne .uwuntu-Datei
        # ----------------------------------------------------
        expected = (
            meta_path.stat().st_size
            + mbr_path.stat().st_size
            + root_zst.stat().st_size
            + persistence_zst.stat().st_size
        )

        p = Progress(
            "Einzelnes .uwuntu-Image erstellen",
            5,
            5,
            expected,
            "SCHREIBEN",
        )

        package_image(temp_dir, final, p)

        log(f"BACKUP ERFOLGREICH: {final}")
        emit(
            "success",
            message="Uwuntu-Image erfolgreich erstellt.",
            image=str(final),
        )

        run(["sync"], check=False)
        run(["udisksctl", "power-off", "-b", disk], check=False)

    except SystemExit:
        raise
    except Exception as exc:
        fail(f"Backup fehlgeschlagen:\n{exc}")
    finally:
        try:
            if subprocess.run(
                ["mountpoint", "-q", str(mount_dir)]
            ).returncode == 0:
                run(["umount", str(mount_dir)], check=False)
        except Exception:
            pass

        shutil.rmtree(mount_dir, ignore_errors=True)
        shutil.rmtree(temp_dir, ignore_errors=True)


# ============================================================
# Restore
# ============================================================

def create_restore_layout(disk, p1_size, p2_needed):
    # Mehrere Parallel-Restores dürfen weiterhin gleichzeitig Daten
    # schreiben. Nur die kurze Partitionstabellen-/udev-Phase wird
    # systemweit serialisiert, damit sich mehrere Sticks nicht mit
    # UDisks/GVFS und udev gegenseitig in die Quere kommen.
    lock_path = Path(
        "/run/lock/uwuntu-image-manager-restore-prepare.lock"
    )
    with lock_path.open("a+") as lock_handle:
        log(f"RESTORE-PREPARE-LOCK: warte für {disk}")
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        log(f"RESTORE-PREPARE-LOCK: aktiv für {disk}")
        try:
            # Bereits laufende Desktop-Mounts zuerst beruhigen. Das
            # eigentliche wipefs besitzt zusätzlich eigene Retries.
            unmount_disk(
                disk,
                retries=4,
                lazy_fallback=True,
            )
            return _create_restore_layout_locked(
                disk,
                p1_size,
                p2_needed,
            )
        finally:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
            log(f"RESTORE-PREPARE-LOCK: frei für {disk}")


def _create_restore_layout_locked(disk, p1_size, p2_needed):
    disk_size = int(output(["blockdev", "--getsize64", disk], timeout=15))
    disk_mib = disk_size // MIB

    # Maximal 29 GiB. Ist der reale "32-GB"-Stick kleiner, wird
    # automatisch ein passendes Layout mit 128 MiB Reserve am Ende
    # gewählt. Dadurch funktionieren z. B. auch Sticks mit 28,64 GiB.
    target_total_mib = min(
        RESTORE_MAX_TOTAL_MIB,
        disk_mib - RESTORE_END_RESERVE_MIB,
    )

    p1_mib = math.ceil(p1_size / MIB)
    p1_start = 1
    p1_end = p1_start + p1_mib
    p2_start = p1_end + 1
    p2_end = target_total_mib

    if target_total_mib <= p2_start:
        fail(
            "Der Zielstick ist zu klein für Boot- und "
            "Persistenzpartition."
        )

    p2_bytes = (p2_end - p2_start) * MIB

    # Nutzdaten + 5 % + 256 MiB Reserve für ext-Metadaten und
    # freien Spielraum.
    safety = int(p2_needed * 1.05) + 256 * MIB

    if p2_bytes < safety:
        fail(
            "Die Persistenz-Daten passen nicht sicher auf diesen "
            "Zielstick.\n\n"
            f"Zielstick: {disk_size / (1024**3):.2f} GiB\n"
            f"Verwendbares Ziellayout: "
            f"{target_total_mib / 1024:.2f} GiB\n"
            f"Für Persistenz verfügbar: "
            f"{p2_bytes / (1024**3):.2f} GiB"
        )

    emit(
        "info",
        message=(
            f"Ziellayout automatisch angepasst: "
            f"{target_total_mib / 1024:.2f} GiB "
            f"auf {disk_size / (1024**3):.2f} GiB Zielstick."
        ),
    )

    log(
        "RESTORE-LAYOUT: "
        f"Disk={disk_size / (1024**3):.2f}GiB "
        f"Layout={target_total_mib / 1024:.2f}GiB "
        f"P1={p1_mib}MiB "
        f"P2={(p2_end - p2_start)}MiB "
        f"Reserve={RESTORE_END_RESERVE_MIB}MiB"
    )

    wipe_disk_for_restore(disk)

    run(["parted", "-s", disk, "mklabel", "gpt"])
    run(
        [
            "parted", "-s", disk,
            "mkpart", "primary", "fat32",
            f"{p1_start}MiB", f"{p1_end}MiB",
        ]
    )
    run(["parted", "-s", disk, "set", "1", "boot", "on"], check=False)
    run(["parted", "-s", disk, "set", "1", "esp", "on"], check=False)
    run(
        [
            "parted", "-s", disk,
            "mkpart", "primary", "ext4",
            f"{p2_start}MiB", f"{p2_end}MiB",
        ]
    )

    run(["partprobe", disk], check=False)
    run(["udevadm", "settle"], check=False)

    p1 = part_path(disk, 1)
    p2 = part_path(disk, 2)

    wait_partition(p1)
    wait_partition(p2)

    return p1, p2


def restore_root_member(image, metadata, target, progress):
    expected_hash = metadata["checksums"]["root.fat.raw.zst"]
    total = int(metadata["partition1"]["size_bytes"])

    zstd, thread, result, log_handle = feed_member_to_zstd(
        image,
        "root.fat.raw.zst",
        expected_hash,
    )

    done = 0

    try:
        with open(target, "wb", buffering=0) as dst:
            while True:
                chunk = zstd.stdout.read(CHUNK)
                if not chunk:
                    break

                dst.write(chunk)
                done += len(chunk)
                progress.update(done)

            dst.flush()
            os.fsync(dst.fileno())

        rc = zstd.wait()
        thread.join()
    finally:
        log_handle.close()

    if rc != 0:
        raise RuntimeError("Boot-Image konnte nicht dekomprimiert werden.")

    check_member_hash(result, expected_hash)

    if done != total:
        raise RuntimeError(
            "Boot-Image hat eine unerwartete Größe "
            f"({done} statt {total} Bytes)."
        )

    progress.finish(done)



def restore_root_partclone_member(image, metadata, target, progress):
    p1_meta = metadata["partition1"]
    member_name = str(p1_meta.get("backup") or "")

    if member_name != "root.fat.partclone.zst":
        raise RuntimeError(
            "Partclone-Boot-Image enthält einen unerwarteten Dateinamen."
        )

    if p1_meta.get("backup_method") != "partclone-vfat":
        raise RuntimeError(
            "Partclone-Boot-Image enthält keine gültige Backup-Methode."
        )

    expected_stream = int(p1_meta.get("partclone_stream_bytes") or 0)
    if expected_stream <= 0:
        raise RuntimeError("Partclone-Streamgröße fehlt im Image.")

    expected_hash = metadata["checksums"][member_name]
    zstd, thread, result, log_handle = feed_member_to_zstd(
        image,
        member_name,
        expected_hash,
    )

    partclone_log = LOG_FILE.open("a", encoding="utf-8")
    partclone_proc = subprocess.Popen(
        [
            "partclone.vfat",
            "-r",
            "-s",
            "-",
            "-o",
            str(target),
            "-q",
        ],
        stdin=subprocess.PIPE,
        stdout=partclone_log,
        stderr=partclone_log,
    )

    done = 0
    zstd_rc = None
    partclone_rc = None
    pipeline_error = None

    try:
        while True:
            chunk = zstd.stdout.read(CHUNK)
            if not chunk:
                break

            partclone_proc.stdin.write(chunk)
            done += len(chunk)
            progress.update(done)

        partclone_proc.stdin.close()
        zstd_rc = zstd.wait()
        partclone_rc = partclone_proc.wait()
        thread.join()
    except Exception as exc:
        pipeline_error = exc
        try:
            partclone_proc.stdin.close()
        except Exception:
            pass

        for proc in (zstd, partclone_proc):
            try:
                if proc.poll() is None:
                    proc.terminate()
            except Exception:
                pass

        try:
            thread.join(timeout=5)
        except Exception:
            pass
    finally:
        log_handle.close()
        partclone_log.close()

    if pipeline_error is not None:
        if result.get("error"):
            raise result["error"]
        raise RuntimeError(
            f"Partclone-Restore-Pipeline fehlgeschlagen: {pipeline_error}"
        ) from pipeline_error
    if zstd_rc != 0:
        raise RuntimeError("Partclone-Boot-Image konnte nicht dekomprimiert werden.")
    if partclone_rc != 0:
        raise RuntimeError("Partclone-Wiederherstellung der Boot-Partition fehlgeschlagen.")

    check_member_hash(result, expected_hash)

    if done != expected_stream:
        raise RuntimeError(
            "Partclone-Boot-Stream hat eine unerwartete Größe "
            f"({done} statt {expected_stream} Bytes)."
        )

    progress.finish(done)


def restore_persistence_member(
    image,
    metadata,
    mountpoint,
    progress,
):
    expected_hash = metadata["checksums"]["persistence.tar.zst"]

    zstd, thread, result, log_handle = feed_member_to_zstd(
        image,
        "persistence.tar.zst",
        expected_hash,
    )

    tar_log = LOG_FILE.open("a", encoding="utf-8")
    tar_proc = subprocess.Popen(
        [
            "tar",
            "--numeric-owner",
            "--xattrs",
            "--acls",
            "-xpf",
            "-",
            "-C",
            str(mountpoint),
        ],
        stdin=subprocess.PIPE,
        stdout=tar_log,
        stderr=tar_log,
    )

    done = 0

    try:
        while True:
            chunk = zstd.stdout.read(CHUNK)
            if not chunk:
                break

            tar_proc.stdin.write(chunk)
            done += len(chunk)
            progress.update(done)

        tar_proc.stdin.close()

        zstd_rc = zstd.wait()
        tar_rc = tar_proc.wait()
        thread.join()
    finally:
        log_handle.close()
        tar_log.close()

    if zstd_rc != 0:
        raise RuntimeError("Persistenz konnte nicht dekomprimiert werden.")
    if tar_rc != 0:
        raise RuntimeError("Persistenz-Dateien konnten nicht geschrieben werden.")

    check_member_hash(result, expected_hash)
    progress.finish(done)


def restore_persistence_partclone_member(
    image,
    metadata,
    target,
    progress,
):
    p2_meta = metadata["partition2"]
    member_name = str(p2_meta.get("backup") or "")

    if member_name != "persistence.ext.partclone.zst":
        raise RuntimeError(
            "Partclone-Persistenz enthält einen unerwarteten Dateinamen."
        )

    expected_stream = int(p2_meta.get("partclone_stream_bytes") or 0)
    if expected_stream <= 0:
        raise RuntimeError("Partclone-Persistenz-Streamgröße fehlt im Image.")

    source_fs = str(p2_meta.get("fstype") or "").lower()
    program = ext_partclone_program(source_fs)
    if p2_meta.get("backup_method") != f"partclone-{source_fs}":
        raise RuntimeError(
            "Partclone-Persistenz enthält keine gültige Backup-Methode."
        )

    expected_hash = metadata["checksums"][member_name]
    zstd, thread, result, log_handle = feed_member_to_zstd(
        image,
        member_name,
        expected_hash,
    )

    partclone_log = LOG_FILE.open("a", encoding="utf-8")
    partclone_proc = subprocess.Popen(
        [program, "-r", "-s", "-", "-o", str(target), "-q"],
        stdin=subprocess.PIPE,
        stdout=partclone_log,
        stderr=partclone_log,
    )

    done = 0
    zstd_rc = None
    partclone_rc = None
    pipeline_error = None

    try:
        while True:
            chunk = zstd.stdout.read(CHUNK)
            if not chunk:
                break

            partclone_proc.stdin.write(chunk)
            done += len(chunk)
            progress.update(done)

        partclone_proc.stdin.close()
        zstd_rc = zstd.wait()
        partclone_rc = partclone_proc.wait()
        thread.join()
    except Exception as exc:
        pipeline_error = exc
        try:
            partclone_proc.stdin.close()
        except Exception:
            pass

        for proc in (zstd, partclone_proc):
            try:
                if proc.poll() is None:
                    proc.terminate()
            except Exception:
                pass

        try:
            thread.join(timeout=5)
        except Exception:
            pass
    finally:
        log_handle.close()
        partclone_log.close()

    if pipeline_error is not None:
        if result.get("error"):
            raise result["error"]
        raise RuntimeError(
            f"Partclone-Persistenz-Restore fehlgeschlagen: {pipeline_error}"
        ) from pipeline_error
    if zstd_rc != 0:
        raise RuntimeError("Partclone-Persistenz konnte nicht dekomprimiert werden.")
    if partclone_rc != 0:
        raise RuntimeError(
            "Partclone-Wiederherstellung der Persistenz ist fehlgeschlagen."
        )

    check_member_hash(result, expected_hash)

    if done != expected_stream:
        raise RuntimeError(
            "Partclone-Persistenz-Stream hat eine unerwartete Größe "
            f"({done} statt {expected_stream} Bytes)."
        )

    progress.finish(done)


def restore(args):
    image = safe_image_path(args.image)
    disk = args.disk

    validate_disk(disk)

    image_disk = disk_for_path(image)

    if image_disk and image_disk == disk:
        fail("Das Restore-Ziel enthält gleichzeitig das ausgewählte Image.")

    metadata = read_metadata(image)

    p1_size = int(metadata["partition1"]["size_bytes"])

    p2_meta = metadata["partition2"]

    if metadata.get("format") == "uwuntu-image-v3":
        p2_used = int(p2_meta.get("compact_size_bytes") or 0)
        if p2_used <= 0:
            raise RuntimeError("Kompakte Persistenzgröße fehlt im Image.")
    else:
        # V1/V2 verwenden weiterhin das bisherige tar-Format.
        p2_used = int(
            p2_meta.get("tar_stream_bytes")
            or p2_meta.get("size_bytes")
            or 0
        )

    mount_dir = Path(tempfile.mkdtemp(prefix="uwuntu-persist-dst-", dir="/mnt"))

    try:
        emit("stage", stage="Zielstick vorbereiten", stage_index=1, stage_count=4, direction="SCHREIBEN")

        p1, p2 = create_restore_layout(
            disk,
            p1_size,
            p2_used,
        )

        emit(
            "progress",
            stage="Zielstick vorbereiten",
            stage_index=1,
            stage_count=4,
            fraction=1.0,
            done=1,
            total=1,
            rate_bps=0,
            eta_seconds=0,
            direction="SCHREIBEN",
        )

        # ----------------------------------------------------
        # 2/4 Boot
        # ----------------------------------------------------
        if metadata.get("format") in {"uwuntu-image-v2", "uwuntu-image-v3"}:
            root_progress_total = int(
                metadata["partition1"].get("partclone_stream_bytes") or 0
            )
            if root_progress_total <= 0:
                raise RuntimeError("Partclone-Streamgröße fehlt im Image.")
        else:
            root_progress_total = p1_size

        p = Progress(
            "Boot-Partition wiederherstellen",
            2,
            4,
            root_progress_total,
            "SCHREIBEN",
        )

        if metadata.get("format") in {"uwuntu-image-v2", "uwuntu-image-v3"}:
            restore_root_partclone_member(image, metadata, p1, p)
        else:
            restore_root_member(image, metadata, p1, p)

        # ----------------------------------------------------
        # 3/4 Persistenz
        # ----------------------------------------------------
        p2_meta = metadata["partition2"]

        source_fs = str(p2_meta.get("fstype") or "").lower()
        if source_fs not in {"ext3", "ext4"}:
            raise RuntimeError(
                "Nicht unterstütztes Persistenz-Dateisystem im Image: "
                f"{source_fs or 'unbekannt'}"
            )

        if metadata.get("format") == "uwuntu-image-v3":
            persistence_total = int(
                p2_meta.get("partclone_stream_bytes") or 0
            )
            if persistence_total <= 0:
                raise RuntimeError(
                    "Partclone-Persistenz-Streamgröße fehlt im Image."
                )

            p = Progress(
                "Persistenz blockweise wiederherstellen",
                3,
                4,
                persistence_total,
                "SCHREIBEN",
            )

            restore_persistence_partclone_member(
                image,
                metadata,
                p2,
                p,
            )

            # Das v3-Image ist bereits sauber geprüft; direkt wachsen.
            # Der schnelle e2fsck -p bleibt in der Abschlussphase erhalten.
            run(["resize2fs", p2])
        else:
            mkfs_program = (
                "mkfs.ext3"
                if source_fs == "ext3"
                else "mkfs.ext4"
            )
            mkfs_args = [mkfs_program, "-F"]

            label = str(p2_meta.get("label") or "")
            uuid = str(p2_meta.get("uuid") or "")

            if label:
                mkfs_args += ["-L", label]

            if re.fullmatch(
                r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-"
                r"[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                r"[0-9a-fA-F]{12}",
                uuid,
            ):
                mkfs_args += ["-U", uuid]

            mkfs_args.append(p2)

            run(mkfs_args)
            run(["mount", p2, str(mount_dir)])

            p = Progress(
                "Persistenz wiederherstellen",
                3,
                4,
                int(p2_meta["tar_stream_bytes"]),
                "SCHREIBEN",
            )

            restore_persistence_member(
                image,
                metadata,
                mount_dir,
                p,
            )

            run(["sync"], check=False)
            run(["umount", str(mount_dir)])

        # ----------------------------------------------------
        # 4/4 Abschlussprüfung
        # ----------------------------------------------------
        p = Progress(
            "Datenträger prüfen und abschließen",
            4,
            4,
            4,
            "PRÜFEN",
        )

        # Falls der Desktop während des Restores doch einen
        # Datenträger erkannt hat, vor fsck erneut sauber aushängen.
        unmount_disk(disk, retries=4, lazy_fallback=True)

        run(["fsck.vfat", "-a", p1], check=False)
        p.update(1, force=True)

        # Keine erzwungene zweite Vollprüfung: auf einem sauberen
        # Dateisystem beendet sich e2fsck hier schnell.
        ext_check = run(["e2fsck", "-p", p2], check=False)
        if ext_check.returncode not in (0, 1):
            raise RuntimeError(
                "Persistenz-Dateisystemprüfung fehlgeschlagen "
                f"(e2fsck Status {ext_check.returncode})."
            )
        p.update(2, force=True)

        mbr = read_member(image, "mbr_bootcode.bin")

        expected_mbr_hash = metadata["checksums"]["mbr_bootcode.bin"]

        if hashlib.sha256(mbr).hexdigest() != expected_mbr_hash:
            raise RuntimeError("MBR-Bootcode-Prüfsumme stimmt nicht.")

        with open(disk, "r+b", buffering=0) as handle:
            handle.seek(0)
            handle.write(mbr[:440])
            handle.flush()
            os.fsync(handle.fileno())

        p.update(3, force=True)

        run(["sync"], check=False)
        run(["partprobe", disk], check=False)
        p.finish(4)

        log(f"RESTORE ERFOLGREICH: {image} -> {disk}")

        # partprobe kann UDisks nochmals aufwecken. Direkt vor dem
        # Power-Off deshalb ein letzter robuster Aushängeversuch.
        unmount_disk(disk, retries=4, lazy_fallback=True)

        # Erst nach einem bestätigten UDisks-Power-Off darf die Oberfläche
        # behaupten, dass der einzelne Stick sicher entfernt werden kann.
        poweroff = run(
            ["udisksctl", "power-off", "-b", disk],
            check=False,
            capture=True,
        )
        safe_to_remove = poweroff.returncode == 0

        if safe_to_remove:
            detail = (
                "Der Stick wurde synchronisiert, sicher ausgeworfen und "
                "kann jetzt entfernt werden."
            )
        else:
            poweroff_detail = (
                (poweroff.stderr or poweroff.stdout or "").strip()
            )
            if poweroff_detail:
                log("UDISKS POWER-OFF FEHLER: " + poweroff_detail)
            detail = (
                "Restore und Dateisystemprüfung sind abgeschlossen, aber "
                "das automatische sichere Auswerfen wurde nicht bestätigt. "
                "Den Stick bitte noch nicht entfernen."
            )

        emit(
            "success",
            message=(
                "Uwuntu wurde erfolgreich auf den Zielstick "
                "wiederhergestellt."
            ),
            detail=detail,
            safe_to_remove=safe_to_remove,
            disk=disk,
        )

    except SystemExit:
        raise
    except Exception as exc:
        fail(f"Restore fehlgeschlagen:\n{exc}")
    finally:
        try:
            if subprocess.run(
                ["mountpoint", "-q", str(mount_dir)]
            ).returncode == 0:
                run(["umount", str(mount_dir)], check=False)
        except Exception:
            pass

        shutil.rmtree(mount_dir, ignore_errors=True)


# ============================================================
# Ventoy Update
# ============================================================

def validate_ventoy_root(root):
    p = Path(root).resolve()

    if not p.is_dir():
        fail("Ventoy-Mountpunkt wurde nicht gefunden.")

    if not (p / "ventoy/ventoy.json").is_file():
        fail(
            "Der ausgewählte Datenträger besitzt keine "
            "ventoy/ventoy.json."
        )

    if not (p / "persistence").is_dir():
        fail(
            "Der ausgewählte Ventoy-Stick besitzt keinen "
            "persistence-Ordner."
        )

    try:
        mountpoint = output(
            ["findmnt", "-T", str(p), "-n", "-o", "TARGET"],
            timeout=4,
        ).splitlines()[0]
    except Exception:
        fail("Ventoy-Mountpunkt konnte nicht geprüft werden.")

    if Path(mountpoint).resolve() != p:
        # Nutzer darf auch Unterordner ausgewählt haben; Frontend liefert
        # normalerweise direkt den echten Mountpunkt.
        p = Path(mountpoint).resolve()

    disk = disk_for_path(p)

    if not disk:
        fail("Der physische Ventoy-Datenträger konnte nicht ermittelt werden.")

    validate_disk(disk)

    return p, disk


def loop_mount(image_file, mountpoint):
    run(["mount", "-o", "loop", str(image_file), str(mountpoint)])


def ventoy_update(args):
    image = safe_image_path(args.image)
    root, disk = validate_ventoy_root(args.ventoy_root)

    image_disk = disk_for_path(image)

    if image_disk and image_disk == disk:
        fail(
            "Das ausgewählte .uwuntu-Image liegt auf demselben "
            "Ventoy-Stick, der aktualisiert werden soll."
        )

    metadata = read_metadata(image)

    target = root / "persistence/Uwuntu.dat"
    previous = root / "persistence/Uwuntu.dat.previous"
    new_file = root / "persistence/Uwuntu.dat.new"

    if not target.is_file():
        fail(
            "Auf dem Ventoy-Stick wurde keine vorhandene "
            "persistence/Uwuntu.dat gefunden.\n\n"
            "Die Ersteinrichtung soll weiterhin unter Windows erfolgen."
        )

    try:
        dat_type = output(
            ["blkid", "-p", "-s", "TYPE", "-o", "value", str(target)],
            timeout=10,
        )
    except Exception:
        dat_type = ""

    try:
        dat_label = output(
            ["blkid", "-p", "-s", "LABEL", "-o", "value", str(target)],
            timeout=10,
        )
    except Exception:
        dat_label = ""

    if dat_type not in {"ext2", "ext3", "ext4"} or dat_label != "casper-rw":
        fail(
            "Die vorhandene Uwuntu.dat hat nicht den erwarteten "
            "Typ/Label (ext + casper-rw)."
        )

    dat_size = target.stat().st_size

    p2_meta = metadata["partition2"]
    if metadata.get("format") == "uwuntu-image-v3":
        required = int(p2_meta.get("compact_size_bytes") or 0)
        if required <= 0:
            raise RuntimeError("Kompakte Persistenzgröße fehlt im Image.")
    else:
        required = int(p2_meta["tar_stream_bytes"] * 1.05) + 256 * MIB

    if dat_size < required:
        fail(
            "Die vorhandene Uwuntu.dat ist zu klein für dieses Image.\n"
            "Es wurde nichts verändert."
        )

    # Eine alte previous-Datei darf Platz freigeben.
    previous.unlink(missing_ok=True)

    usage = shutil.disk_usage(root)

    if usage.free < dat_size + 256 * MIB:
        fail(
            "Auf der Ventoy-Datenpartition ist nicht genug freier "
            "Speicher für eine neue Uwuntu.dat."
        )

    mount_dir = Path(tempfile.mkdtemp(prefix="uwuntu-ventoy-", dir="/mnt"))

    rollback_needed = False
    loopdev = ""

    try:
        # ----------------------------------------------------
        # 1/3 Neue DAT vorbereiten
        # ----------------------------------------------------
        emit(
            "stage",
            stage="Neue Uwuntu.dat vorbereiten",
            stage_index=1,
            stage_count=3,
            direction="SCHREIBEN",
        )

        new_file.unlink(missing_ok=True)

        # Gleiche logische Größe wie die bewährte vorhandene Uwuntu.dat.
        with open(new_file, "wb") as handle:
            handle.truncate(dat_size)

        # UUID der bisherigen DAT beibehalten, wenn lesbar.
        try:
            dat_uuid = output(
                ["blkid", "-p", "-s", "UUID", "-o", "value", str(target)],
                timeout=10,
            )
        except Exception:
            dat_uuid = ""

        if metadata.get("format") != "uwuntu-image-v3":
            mkfs = ["mkfs.ext4", "-F", "-L", "casper-rw"]

            if re.fullmatch(
                r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-"
                r"[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                r"[0-9a-fA-F]{12}",
                dat_uuid,
            ):
                mkfs += ["-U", dat_uuid]

            mkfs.append(str(new_file))
            run(mkfs)

        emit(
            "progress",
            stage="Neue Uwuntu.dat vorbereiten",
            stage_index=1,
            stage_count=3,
            fraction=1.0,
            done=1,
            total=1,
            rate_bps=0,
            eta_seconds=0,
            direction="SCHREIBEN",
        )

        # ----------------------------------------------------
        # 2/3 Persistence hinein
        # ----------------------------------------------------
        if metadata.get("format") == "uwuntu-image-v3":
            persistence_total = int(
                p2_meta.get("partclone_stream_bytes") or 0
            )
            if persistence_total <= 0:
                raise RuntimeError(
                    "Partclone-Persistenz-Streamgröße fehlt im Image."
                )

            loopdev = output(
                ["losetup", "--find", "--show", str(new_file)],
                timeout=10,
            )

            p = Progress(
                "Uwuntu-Inhalt blockweise in Ventoy übertragen",
                2,
                3,
                persistence_total,
                "SCHREIBEN",
            )

            restore_persistence_partclone_member(
                image,
                metadata,
                loopdev,
                p,
            )

            # Auch Ventoy wächst direkt aus der sauberen v3-Kopie.
            run(["resize2fs", loopdev])

            if re.fullmatch(
                r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-"
                r"[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                r"[0-9a-fA-F]{12}",
                dat_uuid,
            ):
                run(["tune2fs", "-U", dat_uuid, loopdev])

            run(["e2label", loopdev, "casper-rw"])

            # Einmalige gemeinsame e2fsck-Prüfung folgt nach dem Detach.
            run(["sync"], check=False)
            run(["losetup", "-d", loopdev], check=False)
            loopdev = ""
        else:
            loop_mount(new_file, mount_dir)

            p = Progress(
                "Uwuntu-Inhalt in Ventoy übertragen",
                2,
                3,
                int(p2_meta["tar_stream_bytes"]),
                "SCHREIBEN",
            )

            restore_persistence_member(
                image,
                metadata,
                mount_dir,
                p,
            )

            run(["sync"], check=False)
            run(["umount", str(mount_dir)])

        ext_check = run(["e2fsck", "-p", str(new_file)], check=False)
        if ext_check.returncode not in (0, 1):
            raise RuntimeError(
                "Neue Uwuntu.dat konnte nicht sauber geprüft werden."
            )

        # ----------------------------------------------------
        # 3/3 Prüfen + atomar ersetzen
        # ----------------------------------------------------
        p = Progress(
            "Uwuntu.dat prüfen und aktivieren",
            3,
            3,
            4,
            "PRÜFEN",
        )

        new_type = output(
            ["blkid", "-p", "-s", "TYPE", "-o", "value", str(new_file)],
            timeout=10,
        )
        new_label = output(
            ["blkid", "-p", "-s", "LABEL", "-o", "value", str(new_file)],
            timeout=10,
        )

        if new_type not in {"ext2", "ext3", "ext4"} or new_label != "casper-rw":
            raise RuntimeError(
                "Neue Uwuntu.dat hat die Sicherheitsprüfung nicht bestanden."
            )

        p.update(1, force=True)

        target.replace(previous)
        rollback_needed = True

        p.update(2, force=True)

        new_file.replace(target)

        p.update(3, force=True)

        # Finale Kontrolle nach Rename.
        final_type = output(
            ["blkid", "-p", "-s", "TYPE", "-o", "value", str(target)],
            timeout=10,
        )
        final_label = output(
            ["blkid", "-p", "-s", "LABEL", "-o", "value", str(target)],
            timeout=10,
        )

        if final_type not in {"ext2", "ext3", "ext4"} or final_label != "casper-rw":
            raise RuntimeError(
                "Finale Uwuntu.dat-Prüfung ist fehlgeschlagen."
            )

        rollback_needed = False
        run(["sync"], check=False)
        p.finish(4)

        log(
            "VENTOY UPDATE ERFOLGREICH: "
            f"{image} -> {target}; ventoy.json/ISO unverändert"
        )

        emit(
            "success",
            message=(
                "Ventoy wurde erfolgreich aktualisiert.\n"
                "Nur persistence/Uwuntu.dat wurde ersetzt."
            ),
        )

    except SystemExit:
        raise
    except Exception as exc:
        if rollback_needed:
            try:
                target.unlink(missing_ok=True)
                previous.replace(target)
                run(["sync"], check=False)
            except Exception:
                pass

        new_file.unlink(missing_ok=True)
        fail(f"Ventoy-Update fehlgeschlagen:\n{exc}")
    finally:
        if loopdev:
            try:
                run(["losetup", "-d", loopdev], check=False)
            except Exception:
                pass

        try:
            if subprocess.run(
                ["mountpoint", "-q", str(mount_dir)]
            ).returncode == 0:
                run(["umount", str(mount_dir)], check=False)
        except Exception:
            pass

        shutil.rmtree(mount_dir, ignore_errors=True)


# ============================================================
# Online-Update
# ============================================================

def version_key(value):
    parts = re.findall(r"\d+", str(value or ""))
    return tuple(int(part) for part in parts) if parts else (0,)


def parse_installer_version(script_text):
    match = re.search(
        r'^APP_VERSION="([0-9]+(?:\.[0-9]+)*)"$',
        script_text,
        flags=re.MULTILINE,
    )
    if not match:
        raise RuntimeError(
            "Die heruntergeladene Datei enthält keine gültige "
            "Uwuntu-Image-Manager-Versionsnummer."
        )
    return match.group(1)


def validate_update_script(script_text):
    required_markers = (
        '#!/usr/bin/env bash',
        'APP_NAME="Uwuntu Image Manager"',
        'ROOT_HELPER="/usr/local/libexec/uwuntu-image-manager-root"',
        'SUDOERS_FILE="/etc/sudoers.d/uwuntu-image-manager"',
        'Uwuntu-Images',
        'persistence/Uwuntu.dat',
    )

    missing = [
        marker for marker in required_markers
        if marker not in script_text
    ]

    if missing:
        raise RuntimeError(
            "Die GitHub-Datei sieht nicht wie ein gültiger "
            "Uwuntu Image Manager aus."
        )


def _github_headers():
    return {
        "User-Agent": f"Uwuntu-Image-Manager/{APP_VERSION}",
        "Accept": "application/vnd.github+json",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
    }


def _download_via_contents_api():
    request = urllib.request.Request(
        UPDATE_API_URL,
        headers=_github_headers(),
    )

    with urllib.request.urlopen(request, timeout=20) as response:
        data = response.read(MAX_UPDATE_BYTES + 1)

    if len(data) > MAX_UPDATE_BYTES:
        raise RuntimeError(
            "Die GitHub-API-Antwort ist unerwartet groß."
        )

    payload = json.loads(data.decode("utf-8"))

    if payload.get("type") != "file":
        raise RuntimeError(
            "Die GitHub-API liefert nicht die erwartete Datei."
        )

    encoded = payload.get("content") or ""
    encoding = (payload.get("encoding") or "").lower()

    if encoding != "base64" or not encoded:
        raise RuntimeError(
            "Die GitHub-API liefert keinen eingebetteten Dateiinhalt."
        )

    raw = base64.b64decode(
        encoded.replace("\n", ""),
        validate=False,
    )

    if len(raw) > MAX_UPDATE_BYTES:
        raise RuntimeError(
            "Die Update-Datei ist unerwartet groß."
        )

    return raw.decode("utf-8")


def _download_via_raw_fallback():
    cache_buster = int(time.time())
    url = f"{UPDATE_RAW_URL}?cb={cache_buster}"

    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": f"Uwuntu-Image-Manager/{APP_VERSION}",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
        },
    )

    with urllib.request.urlopen(request, timeout=25) as response:
        data = response.read(MAX_UPDATE_BYTES + 1)

    if len(data) > MAX_UPDATE_BYTES:
        raise RuntimeError(
            "Die Update-Datei ist unerwartet groß."
        )

    return data.decode("utf-8")


def download_update_script():
    api_error = None

    try:
        script_text = _download_via_contents_api()
        log("UPDATE-QUELLE: GitHub Contents API")
    except Exception as exc:
        api_error = exc
        log(
            "GitHub Contents API fehlgeschlagen; "
            f"Raw-Fallback wird verwendet: {exc}"
        )

        try:
            script_text = _download_via_raw_fallback()
            log("UPDATE-QUELLE: Raw GitHub mit Cache-Buster")
        except Exception as raw_exc:
            raise RuntimeError(
                "GitHub-Update konnte weder über die Repository-API "
                "noch über Raw geladen werden. "
                f"API-Fehler: {api_error}; Raw-Fehler: {raw_exc}"
            ) from raw_exc

    validate_update_script(script_text)
    remote_version = parse_installer_version(script_text)
    return script_text, remote_version


def self_update(args):
    emit(
        "stage",
        stage="Update von GitHub herunterladen",
        stage_index=1,
        stage_count=3,
        direction="DOWNLOAD",
    )

    try:
        script_text, remote_version = download_update_script()
    except Exception as exc:
        fail(f"Update konnte nicht heruntergeladen werden:\n{exc}")

    emit(
        "progress",
        stage="Update von GitHub herunterladen",
        stage_index=1,
        stage_count=3,
        fraction=1.0,
        done=1,
        total=1,
        rate_bps=0,
        eta_seconds=0,
        direction="DOWNLOAD",
    )

    emit(
        "stage",
        stage="Update prüfen",
        stage_index=2,
        stage_count=3,
        direction="PRÜFEN",
    )

    expected = str(args.expected_version or "").strip()

    if expected and remote_version != expected:
        fail(
            "Die GitHub-Version hat sich seit der Prüfung geändert.\n"
            f"Erwartet: v{expected}\n"
            f"Gefunden: v{remote_version}\n\n"
            "Bitte UPDATE PRÜFEN erneut verwenden."
        )

    if version_key(remote_version) <= version_key(APP_VERSION):
        emit(
            "progress",
            stage="Update prüfen",
            stage_index=2,
            stage_count=3,
            fraction=1.0,
            done=1,
            total=1,
            rate_bps=0,
            eta_seconds=0,
            direction="PRÜFEN",
        )
        emit(
            "success",
            message=(
                f"Kein neueres Update vorhanden. "
                f"Installiert: v{APP_VERSION}, GitHub: v{remote_version}"
            ),
            version=APP_VERSION,
            restart=False,
        )
        return

    emit(
        "progress",
        stage="Update prüfen",
        stage_index=2,
        stage_count=3,
        fraction=1.0,
        done=1,
        total=1,
        rate_bps=0,
        eta_seconds=0,
        direction="PRÜFEN",
    )

    emit(
        "stage",
        stage=f"Version {remote_version} installieren",
        stage_index=3,
        stage_count=3,
        direction="INSTALLIEREN",
    )

    temp_path = None

    try:
        fd, temp_name = tempfile.mkstemp(
            prefix="uwuntu-image-manager-update-",
            suffix=".sh",
            dir="/tmp",
        )
        temp_path = Path(temp_name)

        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(script_text)

        os.chmod(temp_path, 0o700)

        log(
            f"ONLINE-UPDATE: v{APP_VERSION} -> v{remote_version} "
            f"von {UPDATE_RAW_URL}"
        )

        result = subprocess.run(
            [
                "bash",
                str(temp_path),
                "--root-update",
                USER,
                str(HOME),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=600,
        )

        if result.stdout:
            log("UPDATE-INSTALLER:\n" + result.stdout[-12000:])

        if result.returncode != 0:
            raise RuntimeError(
                "Der heruntergeladene Installer wurde mit "
                f"Fehlercode {result.returncode} beendet."
            )

    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(
            "Die Update-Installation hat zu lange gedauert."
        ) from exc
    except Exception as exc:
        fail(f"Update-Installation fehlgeschlagen:\n{exc}")
    finally:
        if temp_path:
            try:
                temp_path.unlink(missing_ok=True)
            except Exception:
                pass

    emit(
        "progress",
        stage=f"Version {remote_version} installieren",
        stage_index=3,
        stage_count=3,
        fraction=1.0,
        done=1,
        total=1,
        rate_bps=0,
        eta_seconds=0,
        direction="INSTALLIEREN",
    )

    log(f"ONLINE-UPDATE ERFOLGREICH: v{remote_version}")

    emit(
        "success",
        message=(
            f"Uwuntu Image Manager v{remote_version} wurde "
            "erfolgreich installiert."
        ),
        version=remote_version,
        restart=True,
    )


# ============================================================
# Main
# ============================================================

def main():
    parser = argparse.ArgumentParser()

    sub = parser.add_subparsers(dest="action", required=True)

    p = sub.add_parser("backup")
    p.add_argument("--disk", required=True)

    p = sub.add_parser("restore")
    p.add_argument("--disk", required=True)
    p.add_argument("--image", required=True)

    p = sub.add_parser("benchmark")
    p.add_argument("--disk", required=True)

    p = sub.add_parser("ventoy-update")
    p.add_argument("--image", required=True)
    p.add_argument("--ventoy-root", required=True)

    p = sub.add_parser("self-update")
    p.add_argument("--expected-version", default="")

    args = parser.parse_args()

    log("=" * 70)
    log(f"Uwuntu Image Manager Root Helper v{APP_VERSION} · {args.action}")

    if args.action == "backup":
        backup(args)
    elif args.action == "restore":
        restore(args)
    elif args.action == "benchmark":
        benchmark(args)
    elif args.action == "ventoy-update":
        ventoy_update(args)
    elif args.action == "self-update":
        self_update(args)


if __name__ == "__main__":
    main()
PYROOT

    chmod 0755 "$ROOT_HELPER"
    chown root:root "$ROOT_HELPER"

    cat > "$SUDOERS_FILE" <<EOF
# Uwuntu Image Manager
# Erlaubt ausschließlich den fest installierten Root-Helfer ohne Passwort.
$REAL_USER ALL=(root) NOPASSWD: $ROOT_HELPER
EOF

    chmod 0440 "$SUDOERS_FILE"
    chown root:root "$SUDOERS_FILE"

    if ! visudo -cf "$SUDOERS_FILE"; then
        rm -f "$SUDOERS_FILE"
        echo "sudoers-Prüfung fehlgeschlagen."
        exit 10
    fi

    # --------------------------------------------------------
    # Frontend
    # --------------------------------------------------------
    USER_APP_DIR="$REAL_HOME/.local/share/uwuntu-image-manager"
    USER_BIN_DIR="$REAL_HOME/.local/bin"
    USER_APPLICATIONS="$REAL_HOME/.local/share/applications"
    USER_ICON_DIR="$REAL_HOME/.local/share/icons/hicolor/scalable/apps"
    USER_STATE_DIR="$REAL_HOME/.local/state/uwuntu-image-manager"
    USER_IMAGE_DIR="$REAL_HOME/Uwuntu-Images"

    mkdir -p \
        "$USER_APP_DIR" \
        "$USER_BIN_DIR" \
        "$USER_APPLICATIONS" \
        "$USER_ICON_DIR" \
        "$USER_STATE_DIR" \
        "$USER_IMAGE_DIR"

    cat > "$USER_APP_DIR/uwuntu_image_manager.py" <<'PYAPP'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import base64
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tarfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gtk, Gdk, GLib, Gio

APP_ID = "com.uwuntu.ImageManager"
APP_NAME = "Uwuntu Image Manager"
VERSION = "1.24"

HOME = Path.home()
IMAGE_DIR = HOME / "Uwuntu-Images"
STATE_DIR = HOME / ".local/state/uwuntu-image-manager"
LOG_FILE = STATE_DIR / "manager.log"
ROOT_HELPER = "/usr/local/libexec/uwuntu-image-manager-root"

UPDATE_PAGE_URL = (
    "https://github.com/Davegage-byte/uwuntu/blob/main/"
    "Uwuntu%20Image%20Manager.sh"
)
UPDATE_API_URL = (
    "https://api.github.com/repos/"
    "Davegage-byte/uwuntu/contents/"
    "Uwuntu%20Image%20Manager.sh?ref=main"
)
UPDATE_RAW_URL = (
    "https://raw.githubusercontent.com/"
    "Davegage-byte/uwuntu/main/"
    "Uwuntu%20Image%20Manager.sh"
)
MAX_UPDATE_BYTES = 4 * 1024 * 1024

IMAGE_DIR.mkdir(parents=True, exist_ok=True)
STATE_DIR.mkdir(parents=True, exist_ok=True)


# ============================================================
# Formatierung
# ============================================================

def fmt_bytes(value):
    try:
        value = float(value)
    except Exception:
        return "–"

    units = ["B", "KiB", "MiB", "GiB", "TiB"]

    for unit in units:
        if value < 1024 or unit == units[-1]:
            if unit == "B":
                return f"{int(value)} {unit}"
            return f"{value:.2f} {unit}"
        value /= 1024

    return "–"


def fmt_rate(value):
    try:
        value = float(value)
    except Exception:
        return "–"

    return f"{value / 1_000_000:.1f} MB/s"


def fmt_eta(seconds):
    if seconds is None:
        return "berechne …"

    try:
        seconds = max(0, int(round(float(seconds))))
    except Exception:
        return "berechne …"

    if seconds < 60:
        return f"{seconds} s"

    minutes, sec = divmod(seconds, 60)

    if minutes < 60:
        return f"{minutes}:{sec:02d} min"

    hours, minutes = divmod(minutes, 60)
    return f"{hours} h {minutes:02d} min"


def fmt_duration(seconds):
    try:
        seconds = max(0, int(round(float(seconds))))
    except Exception:
        return "–"

    if seconds < 60:
        return f"{seconds} s"

    minutes, sec = divmod(seconds, 60)

    if minutes < 60:
        return f"{minutes} min {sec:02d} s"

    hours, minutes = divmod(minutes, 60)
    return f"{hours} h {minutes:02d} min {sec:02d} s"


def parse_created(value):
    try:
        when = dt.datetime.fromisoformat(value)
        return when.astimezone().strftime("%d.%m.%Y %H:%M")
    except Exception:
        return value or "unbekannt"


# ============================================================
# Online-Update
# ============================================================

def version_key(value):
    parts = re.findall(r"\d+", str(value or ""))
    return tuple(int(part) for part in parts) if parts else (0,)


def parse_remote_version(script_text):
    match = re.search(
        r'^APP_VERSION="([0-9]+(?:\.[0-9]+)*)"$',
        script_text,
        flags=re.MULTILINE,
    )

    if not match:
        raise RuntimeError(
            "Auf GitHub wurde keine gültige Versionsnummer gefunden."
        )

    return match.group(1)


def _frontend_github_headers():
    return {
        "User-Agent": f"Uwuntu-Image-Manager/{VERSION}",
        "Accept": "application/vnd.github+json",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
    }


def _frontend_fetch_via_api():
    request = urllib.request.Request(
        UPDATE_API_URL,
        headers=_frontend_github_headers(),
    )

    with urllib.request.urlopen(request, timeout=15) as response:
        data = response.read(MAX_UPDATE_BYTES + 1)

    if len(data) > MAX_UPDATE_BYTES:
        raise RuntimeError(
            "Die GitHub-API-Antwort ist unerwartet groß."
        )

    payload = json.loads(data.decode("utf-8"))

    if payload.get("type") != "file":
        raise RuntimeError(
            "Die GitHub-API liefert nicht die erwartete Datei."
        )

    encoded = payload.get("content") or ""
    encoding = (payload.get("encoding") or "").lower()

    if encoding != "base64" or not encoded:
        raise RuntimeError(
            "Die GitHub-API liefert keinen Dateiinhalt."
        )

    raw = base64.b64decode(
        encoded.replace("\n", ""),
        validate=False,
    )

    if len(raw) > MAX_UPDATE_BYTES:
        raise RuntimeError(
            "Die Update-Datei ist unerwartet groß."
        )

    return raw.decode("utf-8")


def _frontend_fetch_via_raw():
    cache_buster = int(dt.datetime.now().timestamp())
    url = f"{UPDATE_RAW_URL}?cb={cache_buster}"

    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": f"Uwuntu-Image-Manager/{VERSION}",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
        },
    )

    with urllib.request.urlopen(request, timeout=20) as response:
        data = response.read(MAX_UPDATE_BYTES + 1)

    if len(data) > MAX_UPDATE_BYTES:
        raise RuntimeError(
            "Die Update-Datei ist unerwartet groß."
        )

    return data.decode("utf-8")


def fetch_remote_version():
    api_error = None

    try:
        script_text = _frontend_fetch_via_api()
    except Exception as exc:
        api_error = exc

        try:
            script_text = _frontend_fetch_via_raw()
        except Exception as raw_exc:
            raise RuntimeError(
                "GitHub konnte weder über die Repository-API "
                "noch über Raw gelesen werden. "
                f"API-Fehler: {api_error}; Raw-Fehler: {raw_exc}"
            ) from raw_exc

    required = (
        '#!/usr/bin/env bash',
        'APP_NAME="Uwuntu Image Manager"',
        'ROOT_HELPER="/usr/local/libexec/uwuntu-image-manager-root"',
    )

    if not all(marker in script_text for marker in required):
        raise RuntimeError(
            "Die GitHub-Datei sieht nicht wie der Uwuntu Image Manager aus."
        )

    return parse_remote_version(script_text)


# ============================================================
# Datenträger
# ============================================================

def run_text(args, timeout=5):
    p = subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=timeout,
        check=False,
    )
    return p.stdout.strip()


def base_disk_for_source(source):
    if not source.startswith("/dev/"):
        return ""

    current = source

    for _ in range(12):
        parent = run_text(["lsblk", "-ndo", "PKNAME", current], 3)
        parent = parent.splitlines()[0].strip() if parent else ""

        if not parent:
            break

        current = "/dev/" + parent

    typ = run_text(["lsblk", "-ndo", "TYPE", current], 3)
    return current if typ == "disk" else ""


def system_disks():
    result = set()

    for target in ("/", "/boot", "/boot/efi", "/cdrom"):
        source = run_text(["findmnt", "-rn", "-o", "SOURCE", target], 3)
        source = source.splitlines()[0].strip() if source else ""

        if not source:
            continue

        disk = base_disk_for_source(source)

        if disk:
            result.add(disk)

    return result


def sysfs_usb(path):
    try:
        name = Path(path).name
        real = os.path.realpath(f"/sys/class/block/{name}/device").lower()
        return "/usb" in real
    except Exception:
        return False


def list_disks():
    p = subprocess.run(
        [
            "lsblk",
            "-J",
            "-b",
            "-d",
            "-o",
            "PATH,SIZE,MODEL,SERIAL,TYPE,RM,TRAN",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )

    try:
        data = json.loads(p.stdout)
    except Exception:
        return []

    blocked = system_disks()
    result = []

    for dev in data.get("blockdevices", []):
        if dev.get("type") != "disk":
            continue

        path = dev.get("path") or ""

        if not path or path in blocked:
            continue

        size = int(dev.get("size") or 0)

        # Keine winzigen Pseudo-Medien.
        if size < 2 * 1024**3:
            continue

        rm = bool(int(dev.get("rm") or 0))
        tran = (dev.get("tran") or "").strip().lower()

        if tran == "usb" or sysfs_usb(path):
            kind = "USB"
        elif rm:
            kind = "Wechselmedium"
        else:
            kind = "Nicht-System"

        result.append(
            {
                "path": path,
                "size": size,
                "model": " ".join(
                    (dev.get("model") or "Unbekannt").split()
                ),
                "serial": (dev.get("serial") or "").strip(),
                "kind": kind,
            }
        )

    result.sort(key=lambda item: (item["kind"] != "USB", item["path"]))
    return result


def compact_text(value, max_len, head=None, tail=None):
    text = str(value or "").strip()

    if len(text) <= max_len:
        return text

    if head is not None and tail is not None:
        return f"{text[:head]}…{text[-tail:]}"

    keep = max(4, max_len - 1)
    return text[:keep] + "…"


def disk_display(item):
    # Lange USB-Seriennummern sprengen sonst Dropdown und Bestätigungsdialog.
    # Intern bleibt die vollständige Seriennummer unverändert erhalten.
    model = compact_text(item.get("model"), 34)
    serial_value = str(item.get("serial") or "").strip()

    if serial_value:
        serial = f" · SN {compact_text(serial_value, 16, head=8, tail=4)}"
    else:
        serial = ""

    return (
        f"{model} · {fmt_bytes(item['size'])} · "
        f"{item['path']} · {item['kind']}{serial}"
    )


# ============================================================
# Images
# ============================================================

def read_image_metadata(path):
    try:
        with tarfile.open(path, "r") as tf:
            handle = tf.extractfile("metadata.json")

            if handle is None:
                return None

            data = json.loads(handle.read().decode("utf-8"))

        if data.get("format") not in {
            "uwuntu-image-v1",
            "uwuntu-image-v2",
            "uwuntu-image-v3",
        }:
            return None

        return data
    except Exception:
        return None


def image_items():
    result = []

    for path in IMAGE_DIR.glob("*.uwuntu"):
        meta = read_image_metadata(path)

        if not meta:
            continue

        result.append(
            {
                "path": path,
                "meta": meta,
                "mtime": path.stat().st_mtime,
                "size": path.stat().st_size,
            }
        )

    result.sort(key=lambda item: item["mtime"], reverse=True)
    return result


def image_display(item):
    meta = item["meta"]
    source = meta.get("source", {})
    return (
        f"{parse_created(meta.get('created'))} · "
        f"{source.get('model', 'Unbekannt')} · "
        f"{fmt_bytes(item['size'])}"
    )


def image_details(item):
    meta = item["meta"]
    source = meta.get("source", {})
    p2 = meta.get("partition2", {})

    return (
        f"Erstellt: {parse_created(meta.get('created'))}\n"
        f"Quelle: {source.get('model', 'Unbekannt')} "
        f"({source.get('path', '–')})\n"
        f"Quellgröße: {fmt_bytes(source.get('size_bytes'))}\n"
        f"Imagegröße: {fmt_bytes(item['size'])}\n"
        f"Persistenzdaten: {fmt_bytes(p2.get('partclone_stream_bytes') or p2.get('tar_stream_bytes'))}\n"
        f"Datei: {item['path'].name}"
    )


# ============================================================
# Ventoy
# ============================================================

def find_ventoy_roots():
    roots = []
    seen = set()

    candidates = []

    for base in (
        Path("/media") / os.environ.get("USER", ""),
        Path("/run/media") / os.environ.get("USER", ""),
    ):
        if base.is_dir():
            candidates.extend(
                child for child in base.iterdir()
                if child.is_dir()
            )

    for child in candidates:
        mount = run_text(
            ["findmnt", "-T", str(child), "-n", "-o", "TARGET"],
            3,
        )

        if not mount:
            continue

        root = Path(mount).resolve()

        if root in seen:
            continue

        if (
            (root / "ventoy/ventoy.json").is_file()
            and (root / "persistence").is_dir()
        ):
            seen.add(root)

            dat = root / "persistence/Uwuntu.dat"

            roots.append(
                {
                    "root": root,
                    "has_dat": dat.is_file(),
                    "dat_size": dat.stat().st_size if dat.is_file() else 0,
                }
            )

    return roots


def ventoy_display(item):
    dat = (
        fmt_bytes(item["dat_size"])
        if item["has_dat"]
        else "Uwuntu.dat fehlt"
    )

    return f"{item['root']} · Uwuntu.dat {dat}"


# ============================================================
# UI-Elemente
# ============================================================

CSS = b"""
window {
    background: #17171c;
    color: #f4f4f5;
}
headerbar {
    background: #202026;
    color: #f4f4f5;
}
.main-title {
    font-size: 30px;
    font-weight: 900;
}
.subtitle {
    color: #9d9da7;
    font-size: 14px;
}
.card {
    background: #232329;
    border: 1px solid #34343c;
    border-radius: 12px;
    padding: 14px;
}
.card-title {
    font-size: 19px;
    font-weight: 900;
}
.card-text {
    color: #b6b6bf;
    font-size: 13px;
}
button.primary {
    min-height: 52px;
    border-radius: 9px;
    font-size: 15px;
    font-weight: 900;
    color: #f4f4f5;
    background: #303037;
    border: 1px solid #5aa2ff;
}
button.primary:hover {
    background: #393944;
}
button.secondary {
    min-height: 40px;
    border-radius: 8px;
    font-size: 13px;
    font-weight: 800;
}
.details {
    background: #1d1d22;
    border: 1px solid #34343c;
    border-radius: 8px;
    padding: 12px;
    color: #d0d0d6;
    font-size: 13px;
}
.warning {
    color: #f5a623;
    font-size: 13px;
    font-weight: 800;
}
.progress-title {
    font-size: 19px;
    font-weight: 900;
}
.progress-info {
    color: #b6b6bf;
    font-size: 14px;
}
progressbar trough {
    min-height: 22px;
    border-radius: 9px;
}
progressbar progress {
    min-height: 22px;
    border-radius: 9px;
}
progressbar.restore-waiting progress {
    background: #6b6b73;
}
progressbar.restore-running progress {
    background: #f5a623;
}
progressbar.restore-ready progress {
    background: #61d36b;
}
progressbar.restore-error progress {
    background: #e85d5d;
}
.batch-summary {
    font-size: 14px;
    font-weight: 900;
}
.batch-stick {
    background: #232329;
    border: 1px solid #34343c;
    border-radius: 8px;
    padding: 5px 7px;
}
.batch-stick-title {
    font-size: 13px;
    font-weight: 900;
}
.batch-stick-detail {
    color: #b6b6bf;
    font-size: 11px;
}
progressbar.batch-progress trough {
    min-height: 14px;
    border-radius: 6px;
}
progressbar.batch-progress progress {
    min-height: 14px;
    border-radius: 6px;
}
.stick-ready {
    color: #61d36b;
    font-weight: 900;
}
.stick-error {
    color: #e85d5d;
    font-weight: 900;
}
"""


def make_label(text, css=None, wrap=True):
    label = Gtk.Label(label=text)
    label.set_xalign(0)

    if wrap:
        label.set_wrap(True)

    if css:
        label.add_css_class(css)

    return label


def dropdown_from_strings(strings):
    return Gtk.DropDown.new_from_strings(strings)


class ProgressWindow(Gtk.Window):
    def __init__(self, parent, title):
        super().__init__(title=title, transient_for=parent, modal=True)

        self.set_default_size(720, 500)
        self.set_deletable(False)

        box = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=12,
        )

        box.set_margin_top(18)
        box.set_margin_bottom(18)
        box.set_margin_start(18)
        box.set_margin_end(18)

        self.set_child(box)

        self.operation_started = time.monotonic()
        self.overall_eta_smoothed = None

        self.stage = make_label("Vorbereitung …", "progress-title")
        box.append(self.stage)

        activity_row = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=8,
        )
        activity_row.set_margin_top(2)
        activity_row.set_margin_bottom(2)
        box.append(activity_row)

        self.activity_spinner = Gtk.Spinner()
        self.activity_spinner.set_spinning(True)
        activity_row.append(self.activity_spinner)

        self.activity_label = make_label(
            "Vorgang läuft …",
            "progress-info",
            wrap=False,
        )
        activity_row.append(self.activity_label)

        self.phase = make_label("")
        self.phase.add_css_class("subtitle")
        box.append(self.phase)

        current_group = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=5,
        )
        current_group.set_margin_top(4)
        box.append(current_group)

        current_label = make_label(
            "AKTUELLE PHASE",
            "progress-info",
        )
        current_group.append(current_label)

        self.bar = Gtk.ProgressBar()
        self.bar.set_show_text(True)
        current_group.append(self.bar)

        self.rate = make_label(
            "Aktuelle Rate: –",
            "progress-info",
        )
        current_group.append(self.rate)

        self.phase_eta = make_label(
            "Restzeit aktuelle Phase: berechne …",
            "progress-info",
        )
        current_group.append(self.phase_eta)

        overall_group = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=5,
        )
        overall_group.set_margin_top(20)
        box.append(overall_group)

        overall_label = make_label(
            "GESAMTFORTSCHRITT",
            "progress-info",
        )
        overall_group.append(overall_label)

        self.overall_bar = Gtk.ProgressBar()
        self.overall_bar.set_show_text(True)
        overall_group.append(self.overall_bar)

        self.overall_eta = make_label(
            "Gesamte Restzeit: berechne …",
            "progress-info",
        )
        overall_group.append(self.overall_eta)

        self.note = make_label(
            "Bitte den Datenträger während des Vorgangs nicht entfernen.",
            "subtitle",
        )
        self.note.set_margin_top(10)
        box.append(self.note)

        self.present()

    def update_overall_eta(self, overall_fraction):
        overall_fraction = max(
            0.0,
            min(1.0, float(overall_fraction or 0)),
        )

        if overall_fraction >= 0.999:
            self.overall_eta_smoothed = 0.0
            self.overall_eta.set_text("Gesamte Restzeit: 0 s")
            return

        elapsed = max(
            0.0,
            time.monotonic() - self.operation_started,
        )

        if overall_fraction < 0.01 or elapsed < 2.0:
            self.overall_eta.set_text(
                "Gesamte Restzeit: berechne …"
            )
            return

        raw_eta = (
            elapsed
            * (1.0 - overall_fraction)
            / overall_fraction
        )

        if self.overall_eta_smoothed is None:
            self.overall_eta_smoothed = raw_eta
        else:
            # Deutlich glätten, damit die Gesamt-ETA bei schwankender
            # USB-Rate und Phasenwechseln nicht hektisch springt.
            self.overall_eta_smoothed = (
                0.82 * self.overall_eta_smoothed
                + 0.18 * raw_eta
            )

        self.overall_eta.set_text(
            "Gesamte Restzeit: ca. "
            + fmt_eta(self.overall_eta_smoothed)
        )

    def handle_event(self, data):
        typ = data.get("type")

        if typ == "stage":
            self.stage.set_text(data.get("stage", ""))

            try:
                idx = int(data.get("stage_index") or 1)
            except Exception:
                idx = 1

            try:
                count = max(1, int(data.get("stage_count") or 1))
            except Exception:
                count = 1

            self.phase.set_text(f"Phase {idx} von {count}")

            self.bar.set_fraction(0)
            self.bar.set_text("0 %")

            overall_fraction = max(
                0.0,
                min(1.0, (idx - 1) / count),
            )
            self.overall_bar.set_fraction(overall_fraction)
            self.overall_bar.set_text(
                f"{overall_fraction * 100:.0f} %"
            )

            self.rate.set_text("Aktuelle Rate: –")
            self.phase_eta.set_text(
                "Restzeit aktuelle Phase: berechne …"
            )
            self.update_overall_eta(overall_fraction)

        elif typ == "progress":
            fraction = max(
                0.0,
                min(1.0, float(data.get("fraction") or 0)),
            )

            self.bar.set_fraction(fraction)
            self.bar.set_text(f"{fraction * 100:.0f} %")

            try:
                idx = int(data.get("stage_index") or 1)
            except Exception:
                idx = 1

            try:
                count = max(1, int(data.get("stage_count") or 1))
            except Exception:
                count = 1

            overall_fraction = (
                (idx - 1) + fraction
            ) / count
            overall_fraction = max(
                0.0,
                min(1.0, overall_fraction),
            )

            self.overall_bar.set_fraction(overall_fraction)
            self.overall_bar.set_text(
                f"{overall_fraction * 100:.0f} %"
            )

            direction = data.get("direction") or "ÜBERTRAGEN"
            self.rate.set_text(
                f"{direction}: {fmt_rate(data.get('rate_bps'))}"
            )
            self.phase_eta.set_text(
                "Restzeit aktuelle Phase: ca. "
                + fmt_eta(data.get("eta_seconds"))
            )
            self.update_overall_eta(overall_fraction)

        elif typ == "info":
            self.note.set_text(data.get("message", ""))

        elif typ == "success":
            self.activity_spinner.set_spinning(False)
            self.activity_label.set_text("Vorgang abgeschlossen")

        elif typ == "error":
            self.activity_spinner.set_spinning(False)
            self.activity_label.set_text("Vorgang beendet")



class BatchTimeline(Gtk.DrawingArea):
    """Gemeinsame Zeitachse mit erwarteten Fertig-Zeitpunkten je Stick."""

    def __init__(self, owner):
        super().__init__()
        self.owner = owner
        self.set_content_height(46)
        self.set_hexpand(True)
        self.set_draw_func(self._draw)

    def _draw(self, _area, cr, width, height):
        states = self.owner.states
        elapsed = self.owner.elapsed()

        if not states or width < 80:
            return

        predictions = []
        for state in states:
            finish = state.get("finished_elapsed")
            if finish is None:
                eta = state.get("eta")
                if eta is not None and state.get("status") in {"running", "waiting"}:
                    finish = elapsed + max(0.0, float(eta))
            predictions.append(finish)

        known = [float(value) for value in predictions if value is not None]
        horizon = max([elapsed + 1.0, *known])
        terminal = all(
            state.get("status") in {"ready", "done_not_ejected", "error"}
            for state in states
        )
        if terminal and known:
            horizon = max(known)
        horizon = max(1.0, horizon)

        x0 = 8.0
        bar_w = max(10.0, float(width) - 16.0)
        bar_y = 15.0
        bar_h = 12.0

        # Hintergrund.
        cr.set_source_rgb(0.20, 0.20, 0.24)
        cr.rectangle(x0, bar_y, bar_w, bar_h)
        cr.fill()

        # Verstrichener Batch-Anteil auf der gemeinsamen Zeitachse.
        if terminal and all(state.get("status") == "ready" for state in states):
            cr.set_source_rgb(0.38, 0.83, 0.42)
            batch_fraction = 1.0
        elif terminal and any(state.get("status") == "error" for state in states):
            cr.set_source_rgb(0.91, 0.36, 0.36)
            batch_fraction = 1.0
        else:
            cr.set_source_rgb(0.96, 0.65, 0.14)
            batch_fraction = min(1.0, elapsed / horizon)

        cr.rectangle(x0, bar_y, bar_w * batch_fraction, bar_h)
        cr.fill()

        cr.set_font_size(10.0)

        for index, (state, finish) in enumerate(zip(states, predictions), start=1):
            if finish is None:
                continue

            pos = min(1.0, max(0.0, float(finish) / horizon))
            x = x0 + bar_w * pos

            status = state.get("status")
            if status == "ready":
                cr.set_source_rgb(0.38, 0.83, 0.42)
            elif status == "error":
                cr.set_source_rgb(0.91, 0.36, 0.36)
            else:
                cr.set_source_rgb(0.96, 0.65, 0.14)

            cr.set_line_width(2.0)
            cr.move_to(x, 11.0)
            cr.line_to(x, bar_y + bar_h + 4.0)
            cr.stroke()

            label = str(index)
            ext = cr.text_extents(label)
            try:
                label_w = ext.width
            except Exception:
                label_w = ext[2]
            cr.move_to(x - label_w / 2.0, 9.0)
            cr.show_text(label)

        # Zeitachse links/rechts klein beschriften.
        cr.set_source_rgb(0.65, 0.65, 0.70)
        cr.set_font_size(10.0)
        cr.move_to(x0, float(height) - 2.0)
        cr.show_text("0:00")

        right = fmt_eta(max(0.0, horizon - elapsed))
        ext = cr.text_extents(right)
        try:
            right_w = ext.width
        except Exception:
            right_w = ext[2]
        cr.move_to(
            max(x0, x0 + bar_w - right_w),
            float(height) - 2.0,
        )
        cr.show_text(right)


class BatchRestoreWindow(Gtk.Window):
    TERMINAL = {"ready", "done_not_ejected", "error"}

    def __init__(self, parent, image, disks):
        super().__init__(
            title="Uwuntu Parallel-Restore",
            transient_for=parent,
            modal=True,
        )
        # 2 Spalten x maximal 5 Reihen: zehn Sticks passen ohne Scrollen
        # zusammen mit Übersicht und Gesamt-Zeitachse in ein normales Display.
        self.set_default_size(1180, 690)
        self.set_deletable(False)

        self.parent_window = parent
        self.image = image
        self.batch_started = time.monotonic()
        self.states = []
        self.rows = []
        self.timeout_id = None

        root = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=6,
        )
        root.set_margin_top(10)
        root.set_margin_bottom(10)
        root.set_margin_start(10)
        root.set_margin_end(10)
        self.set_child(root)

        header = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=12,
        )
        root.append(header)

        title = make_label("PARALLEL-RESTORE", "card-title", wrap=False)
        title.set_hexpand(True)
        header.append(title)

        legend = make_label(
            "Orange = läuft · Grün = sicher ausgeworfen / entfernbar",
            "subtitle",
            wrap=False,
        )
        legend.set_xalign(1.0)
        header.append(legend)

        overview = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=12,
        )
        root.append(overview)

        self.summary = make_label("", "batch-summary", wrap=False)
        self.summary.set_hexpand(True)
        overview.append(self.summary)

        self.batch_eta = make_label(
            "Batch-Prognose wird berechnet …",
            "progress-info",
            wrap=False,
        )
        self.batch_eta.set_xalign(1.0)
        overview.append(self.batch_eta)

        self.timeline = BatchTimeline(self)
        root.append(self.timeline)

        # Kein Scroller: maximal zehn kompakte Kacheln werden als 2 x 5
        # Dashboard angeordnet. So bleibt auch der Gesamtverlauf sichtbar.
        tiles = Gtk.Grid(column_spacing=6, row_spacing=6)
        tiles.set_column_homogeneous(True)
        tiles.set_vexpand(True)
        root.append(tiles)

        for index, disk in enumerate(disks, start=1):
            state = {
                "disk": disk,
                "status": "waiting",
                "started": None,
                "stage": "Wartet auf Start …",
                "stage_index": 0,
                "stage_count": 4,
                "phase_fraction": 0.0,
                "overall_fraction": 0.0,
                "rate_bps": 0.0,
                "eta": None,
                "finished_elapsed": None,
                "error": "",
            }
            self.states.append(state)

            tile = Gtk.Box(
                orientation=Gtk.Orientation.VERTICAL,
                spacing=2,
            )
            tile.add_css_class("batch-stick")
            tile.set_hexpand(True)
            tile.set_vexpand(True)

            model = compact_text(disk.get("model", "Unbekannt"), 27)
            title_label = make_label(
                f"Stick {index} · {model} · {disk['path']}",
                "batch-stick-title",
                wrap=False,
            )
            tile.append(title_label)

            bar = Gtk.ProgressBar()
            bar.set_show_text(True)
            bar.set_fraction(0.0)
            bar.set_text("0 %")
            bar.add_css_class("batch-progress")
            bar.add_css_class("restore-waiting")
            tile.append(bar)

            detail_label = make_label(
                "Wartet auf Start …",
                "batch-stick-detail",
                wrap=False,
            )
            tile.append(detail_label)

            position = index - 1
            column = position % 2
            row_number = position // 2
            tiles.attach(tile, column, row_number, 1, 1)

            self.rows.append(
                {
                    "bar": bar,
                    "detail": detail_label,
                }
            )

        self.close_button = Gtk.Button(label="SCHLIESSEN")
        self.close_button.add_css_class("secondary")
        self.close_button.set_sensitive(False)
        self.close_button.connect("clicked", lambda *_: self.close())
        root.append(self.close_button)

        self._refresh_all()
        self.present()

    def elapsed(self):
        return max(0.0, time.monotonic() - self.batch_started)

    def start(self):
        self.batch_started = time.monotonic()
        for index, state in enumerate(self.states):
            state["status"] = "running"
            state["started"] = time.monotonic()
            self._refresh_row(index)
            threading.Thread(
                target=self._worker,
                args=(index,),
                daemon=True,
            ).start()

        self.timeout_id = GLib.timeout_add_seconds(1, self._tick)
        self._refresh_all()

    def _worker(self, index):
        state = self.states[index]
        disk = state["disk"]
        command = [
            "sudo",
            "-n",
            ROOT_HELPER,
            "restore",
            "--disk",
            disk["path"],
            "--image",
            str(self.image["path"]),
        ]

        saw_success = False
        saw_error = False

        try:
            proc = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )

            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue

                try:
                    event = json.loads(line)
                except Exception:
                    continue

                if event.get("type") == "success":
                    saw_success = True
                elif event.get("type") == "error":
                    saw_error = True

                GLib.idle_add(self.handle_event, index, event)

            rc = proc.wait()

            if rc != 0 and not saw_error:
                GLib.idle_add(
                    self.handle_event,
                    index,
                    {
                        "type": "error",
                        "message": (
                            "Restore-Prozess wurde mit einem Fehler beendet. "
                            "Details stehen im Log."
                        ),
                    },
                )
            elif rc == 0 and not saw_success:
                GLib.idle_add(
                    self.handle_event,
                    index,
                    {
                        "type": "error",
                        "message": "Restore endete ohne Erfolgsbestätigung.",
                    },
                )
        except Exception as exc:
            GLib.idle_add(
                self.handle_event,
                index,
                {"type": "error", "message": str(exc)},
            )

    def _set_bar_class(self, bar, css_class):
        for name in (
            "restore-waiting",
            "restore-running",
            "restore-ready",
            "restore-error",
        ):
            bar.remove_css_class(name)
        bar.add_css_class(css_class)

    def handle_event(self, index, data):
        state = self.states[index]
        typ = data.get("type")

        if typ == "stage":
            state["stage"] = data.get("stage", "")
            state["stage_index"] = int(data.get("stage_index") or 1)
            state["stage_count"] = max(1, int(data.get("stage_count") or 1))
            state["phase_fraction"] = 0.0
            state["overall_fraction"] = max(
                0.0,
                min(
                    1.0,
                    (state["stage_index"] - 1) / state["stage_count"],
                ),
            )

        elif typ == "progress":
            fraction = max(
                0.0,
                min(1.0, float(data.get("fraction") or 0.0)),
            )
            stage_index = int(data.get("stage_index") or state["stage_index"] or 1)
            stage_count = max(1, int(data.get("stage_count") or state["stage_count"] or 1))

            state["stage"] = data.get("stage") or state["stage"]
            state["stage_index"] = stage_index
            state["stage_count"] = stage_count
            state["phase_fraction"] = fraction
            state["overall_fraction"] = max(
                0.0,
                min(1.0, ((stage_index - 1) + fraction) / stage_count),
            )
            try:
                state["rate_bps"] = float(data.get("rate_bps") or 0.0)
            except Exception:
                state["rate_bps"] = 0.0

            started = state.get("started")
            elapsed = max(0.0, time.monotonic() - started) if started else 0.0
            overall = state["overall_fraction"]
            if overall >= 0.01 and overall < 0.999 and elapsed >= 2.0:
                raw_eta = elapsed * (1.0 - overall) / overall
                if state["eta"] is None:
                    state["eta"] = raw_eta
                else:
                    state["eta"] = 0.84 * state["eta"] + 0.16 * raw_eta
            elif overall >= 0.999:
                state["eta"] = 0.0

        elif typ == "success":
            state["overall_fraction"] = 1.0
            state["phase_fraction"] = 1.0
            state["eta"] = 0.0
            state["finished_elapsed"] = self.elapsed()

            if bool(data.get("safe_to_remove")):
                state["status"] = "ready"
                state["stage"] = "Fertig"
            else:
                state["status"] = "done_not_ejected"
                state["stage"] = "Restore fertig · Auswerfen nicht bestätigt"

        elif typ == "error":
            state["status"] = "error"
            state["error"] = data.get("message", "Unbekannter Fehler.")
            state["eta"] = 0.0
            state["finished_elapsed"] = self.elapsed()

        self._refresh_row(index)
        self._refresh_summary()
        self.timeline.queue_draw()
        return False

    def _refresh_row(self, index):
        state = self.states[index]
        row = self.rows[index]
        status = state["status"]
        fraction = max(0.0, min(1.0, state["overall_fraction"]))

        row["bar"].set_fraction(fraction)
        row["bar"].set_text(f"{fraction * 100:.0f} %")

        if status == "ready":
            self._set_bar_class(row["bar"], "restore-ready")
        elif status == "error":
            self._set_bar_class(row["bar"], "restore-error")
        elif status == "waiting":
            self._set_bar_class(row["bar"], "restore-waiting")
        else:
            self._set_bar_class(row["bar"], "restore-running")

        started = state.get("started")
        elapsed = max(0.0, time.monotonic() - started) if started else 0.0
        elapsed_text = fmt_duration(elapsed)

        detail = row["detail"]
        detail.remove_css_class("stick-ready")
        detail.remove_css_class("stick-error")

        if status == "ready":
            detail.set_text(
                "✓ FERTIG · sicher ausgeworfen · "
                + elapsed_text
                + " · kann entfernt werden"
            )
            detail.add_css_class("stick-ready")
        elif status == "done_not_ejected":
            detail.set_text(
                "⚠ Restore fertig · "
                + elapsed_text
                + " · Auswerfen nicht bestätigt · NICHT entfernen"
            )
        elif status == "error":
            detail.set_text(
                "✕ FEHLER · " + compact_text(state.get("error"), 78)
            )
            detail.add_css_class("stick-error")
        else:
            stage_index = state.get("stage_index") or 0
            stage_count = state.get("stage_count") or 4
            rate = fmt_rate(state.get("rate_bps"))
            eta = fmt_eta(state.get("eta"))
            stage = compact_text(state.get("stage"), 31)

            if stage_index:
                detail.set_text(
                    f"P{stage_index}/{stage_count} · {stage} · {rate} · "
                    f"{elapsed_text} · Rest {eta}"
                )
            else:
                detail.set_text(
                    f"{stage} · {elapsed_text} · Rest {eta}"
                )

    def _refresh_summary(self):
        counts = {
            "waiting": 0,
            "running": 0,
            "ready": 0,
            "done_not_ejected": 0,
            "error": 0,
        }
        for state in self.states:
            counts[state["status"]] = counts.get(state["status"], 0) + 1

        parts = [f"{len(self.states)} STICKS"]
        if counts["running"]:
            parts.append(f"{counts['running']} laufen")
        if counts["ready"]:
            parts.append(f"{counts['ready']} sicher entfernbar")
        if counts["done_not_ejected"]:
            parts.append(f"{counts['done_not_ejected']} nicht ausgeworfen")
        if counts["error"]:
            parts.append(f"{counts['error']} Fehler")
        if counts["waiting"]:
            parts.append(f"{counts['waiting']} warten")

        self.summary.set_text(" · ".join(parts))

        active_etas = [
            state.get("eta")
            for state in self.states
            if state.get("status") in {"running", "waiting"}
            and state.get("eta") is not None
        ]

        if all(state["status"] in self.TERMINAL for state in self.states):
            self.batch_eta.set_text(
                "Batch abgeschlossen · Gesamtzeit " + fmt_duration(self.elapsed())
            )
            self.set_deletable(True)
            self.close_button.set_sensitive(True)
        elif active_etas:
            self.batch_eta.set_text(
                "Gesamtzeit "
                + fmt_duration(self.elapsed())
                + " · Batch voraussichtlich fertig in ca. "
                + fmt_eta(max(active_etas))
            )
        else:
            self.batch_eta.set_text(
                "Gesamtzeit "
                + fmt_duration(self.elapsed())
                + " · Batch-Prognose wird berechnet …"
            )

    def _refresh_all(self):
        for index in range(len(self.states)):
            self._refresh_row(index)
        self._refresh_summary()
        self.timeline.queue_draw()

    def _tick(self):
        self._refresh_all()
        if all(state["status"] in self.TERMINAL for state in self.states):
            self.timeout_id = None
            return False
        return True


class ActionWindow(Gtk.Window):
    def __init__(self, parent, title):
        super().__init__(title=title, transient_for=parent, modal=True)
        self.set_default_size(920, 620)

        self.root = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=12,
        )

        self.root.set_margin_top(16)
        self.root.set_margin_bottom(16)
        self.root.set_margin_start(16)
        self.root.set_margin_end(16)

        self.set_child(self.root)


class MainWindow(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app)

        self.set_title(f"{APP_NAME} v{VERSION}")
        self.set_default_size(900, 760)

        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        root = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=12,
        )

        root.set_margin_top(24)
        root.set_margin_bottom(24)
        root.set_margin_start(24)
        root.set_margin_end(24)

        self.set_child(root)

        title = make_label("UWUNTU IMAGE MANAGER", "main-title")
        root.append(title)

        subtitle = make_label(
            "Ein Tool für Master-Backup, neue Uwuntu-Sticks und "
            "das Aktualisieren deines bestehenden Ventoy-Sticks.",
            "subtitle",
        )
        root.append(subtitle)

        root.append(
            self.action_card(
                "UWUNTU SICHERN",
                "Erstellt aus einem eingesteckten Uwuntu-Master-Stick "
                "eine einzelne .uwuntu-Datei. Das Image landet automatisch "
                "im Uwuntu-Image-Ordner und enthält Datum, Geräteinformationen "
                "und Prüfsummen.",
                self.open_backup,
            )
        )

        root.append(
            self.action_card(
                "UWUNTU WIEDERHERSTELLEN",
                "Schreibt ein gespeichertes .uwuntu-Image auf einen oder "
                "mehrere Sticks gleichzeitig. Jeder Stick hat eigenen "
                "Fortschritt, Rate und Restzeit und wird nach erfolgreichem "
                "Abschluss einzeln sicher ausgeworfen.",
                self.open_restore,
            )
        )

        root.append(
            self.action_card(
                "VENTOY AKTUALISIEREN",
                "Aktualisiert auf einem bereits eingerichteten Ventoy-Stick "
                "ausschließlich persistence/Uwuntu.dat. ventoy.json, Theme, "
                "Uwuntu.iso, Windows-Dateien und sonstige Einstellungen "
                "bleiben unverändert.",
                self.open_ventoy,
            )
        )

        bottom = Gtk.Grid(column_spacing=8, row_spacing=8)

        root.append(bottom)

        show_images = Gtk.Button(label="IMAGES ANZEIGEN")
        show_images.add_css_class("secondary")
        show_images.set_hexpand(True)
        show_images.connect("clicked", self.open_images)
        bottom.attach(show_images, 0, 0, 1, 1)

        open_image_folder = Gtk.Button(label="IMAGE-ORDNER ÖFFNEN")
        open_image_folder.add_css_class("secondary")
        open_image_folder.set_hexpand(True)
        open_image_folder.connect("clicked", self.open_image_folder)
        bottom.attach(open_image_folder, 1, 0, 1, 1)

        self.update_button = Gtk.Button(label="UPDATE PRÜFEN")
        self.update_button.add_css_class("secondary")
        self.update_button.set_hexpand(True)
        self.update_button.connect("clicked", self.check_for_update)
        bottom.attach(self.update_button, 0, 1, 1, 1)

        open_log = Gtk.Button(label="LOG ÖFFNEN")
        open_log.add_css_class("secondary")
        open_log.set_hexpand(True)
        open_log.connect("clicked", self.open_log)
        bottom.attach(open_log, 1, 1, 1, 1)

        benchmark_button = Gtk.Button(label="USB-BENCHMARK")
        benchmark_button.add_css_class("secondary")
        benchmark_button.set_hexpand(True)
        benchmark_button.connect("clicked", self.open_benchmark)
        bottom.attach(benchmark_button, 0, 2, 1, 1)

    def action_card(self, title, text, callback):
        frame = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=8,
        )
        frame.add_css_class("card")

        frame.append(make_label(title, "card-title"))
        frame.append(make_label(text, "card-text"))

        button = Gtk.Button(label=title)
        button.add_css_class("primary")
        button.connect("clicked", callback)
        frame.append(button)

        return frame

    def error(self, message):
        dialog = Gtk.AlertDialog()
        dialog.set_message("FEHLER")
        dialog.set_detail(message)
        dialog.show(self)

    def info(self, message, detail=""):
        dialog = Gtk.AlertDialog()
        dialog.set_message(message)

        if detail:
            dialog.set_detail(detail)

        dialog.show(self)

    def confirm(self, title, detail, callback):
        dialog = Gtk.AlertDialog()
        dialog.set_message(title)
        dialog.set_detail(detail)
        dialog.set_buttons(["ABBRECHEN", "STARTEN"])
        dialog.set_default_button(0)
        dialog.set_cancel_button(0)

        def done(dlg, result):
            try:
                choice = dlg.choose_finish(result)
            except Exception:
                return

            if choice == 1:
                callback()

        dialog.choose(self, None, done)

    def open_image_folder(self, *_):
        IMAGE_DIR.mkdir(parents=True, exist_ok=True)
        subprocess.Popen(
            ["xdg-open", str(IMAGE_DIR)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def open_images(self, *_):
        images = image_items()

        if not images:
            self.error(
                "Im Uwuntu-Image-Ordner wurde noch kein gültiges "
                ".uwuntu-Image gefunden."
            )
            return

        win = ActionWindow(self, "Gespeicherte Images")
        win.root.append(make_label("GESPEICHERTE IMAGES", "card-title"))
        win.root.append(
            make_label(
                "Wähle ein Image aus, um die gespeicherten Details "
                "anzuzeigen.",
                "card-text",
            )
        )

        image_dd = dropdown_from_strings(
            [image_display(item) for item in images]
        )
        win.root.append(image_dd)

        details = make_label(image_details(images[0]), "details")
        win.root.append(details)

        def image_changed(dd, _pspec):
            idx = dd.get_selected()

            if idx < len(images):
                details.set_text(image_details(images[idx]))

        image_dd.connect("notify::selected", image_changed)

        buttons = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=8,
        )
        win.root.append(buttons)

        close = Gtk.Button(label="SCHLIESSEN")
        close.add_css_class("secondary")
        close.set_hexpand(True)
        close.connect("clicked", lambda *_: win.close())
        buttons.append(close)

        open_folder = Gtk.Button(label="IMAGE-ORDNER ÖFFNEN")
        open_folder.add_css_class("secondary")
        open_folder.set_hexpand(True)
        open_folder.connect("clicked", self.open_image_folder)
        buttons.append(open_folder)

        win.present()

    def open_log(self, *_):
        LOG_FILE.touch(exist_ok=True)
        subprocess.Popen(
            ["xdg-open", str(LOG_FILE)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    # --------------------------------------------------------
    # USB-Benchmark
    # --------------------------------------------------------
    def open_benchmark(self, *_):
        disks = [
            item
            for item in list_disks()
            if item.get("kind") in {"USB", "Wechselmedium"}
        ]

        if not disks:
            self.error(
                "Kein geeigneter USB-/Wechseldatenträger wurde gefunden.\n\n"
                "Stick einstecken und die Funktion erneut öffnen."
            )
            return

        win = ActionWindow(self, "USB-Benchmark")
        win.root.append(make_label("USB-BENCHMARK", "card-title"))
        win.root.append(
            make_label(
                "Misst zuerst die sequenzielle Schreib- und Lesegeschwindigkeit "
                "mit jeweils 512 MiB und danach 4K-Random-Zugriffe mit QD1 "
                "für Lesen und Schreiben. Die beiden Random-Tests dauern "
                "jeweils nur 8 Sekunden.",
                "card-text",
            )
        )

        dropdown = dropdown_from_strings(
            [disk_display(item) for item in disks]
        )
        win.root.append(dropdown)

        warning = make_label(
            "ACHTUNG: Der Test überschreibt die ersten 512 MiB des "
            "ausgewählten Sticks. Vorhandene Partitionen/Daten werden "
            "dadurch unbrauchbar.",
            "warning",
        )
        win.root.append(warning)

        note = make_label(
            "Test: 512 MiB sequenziell schreiben und verifizieren → "
            "4K Random Write 8 s → Cache leeren → 4K Random Read 8 s. "
            "Ergebnis: MB/s sowie Random-IOPS und Latenz.",
            "details",
        )
        win.root.append(note)

        buttons = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=8,
        )
        win.root.append(buttons)

        cancel = Gtk.Button(label="ABBRECHEN")
        cancel.add_css_class("secondary")
        cancel.set_hexpand(True)
        cancel.connect("clicked", lambda *_: win.close())
        buttons.append(cancel)

        start = Gtk.Button(label="BENCHMARK STARTEN")
        start.add_css_class("primary")
        start.set_hexpand(True)

        def clicked(*_):
            idx = dropdown.get_selected()
            if idx >= len(disks):
                return

            disk = disks[idx]

            self.confirm(
                "USB-STICK WIRKLICH TESTEN?",
                f"Ziel:\n{disk_display(disk)}\n\n"
                "Die ersten 512 MiB des Sticks werden überschrieben. "
                "Damit gehen vorhandene Partitionsinformationen und "
                "Daten auf dem Stick verloren.\n\n"
                "Nach dem Benchmark muss der Stick neu formatiert oder "
                "mit dem Uwuntu Image Manager wiederhergestellt werden.",
                lambda: (
                    win.close(),
                    self.run_backend(
                        "USB-BENCHMARK · SEQ + 4K RANDOM",
                        ["benchmark", "--disk", disk["path"]],
                    ),
                ),
            )

        start.connect("clicked", clicked)
        buttons.append(start)
        win.present()

    # --------------------------------------------------------
    # Online-Update
    # --------------------------------------------------------
    def check_for_update(self, *_):
        self.update_button.set_sensitive(False)
        self.update_button.set_label("PRÜFE GITHUB …")

        def worker():
            remote_version = None
            error = None

            try:
                remote_version = fetch_remote_version()
            except Exception as exc:
                error = str(exc)

            def finish():
                self.update_button.set_sensitive(True)
                self.update_button.set_label("UPDATE PRÜFEN")

                if error:
                    self.error(
                        "Update-Prüfung fehlgeschlagen.\n\n" + error
                    )
                    return False

                if version_key(remote_version) <= version_key(VERSION):
                    self.info(
                        "KEIN NEUERES UPDATE",
                        f"Installiert: v{VERSION}\n"
                        f"GitHub: v{remote_version}\n\n"
                        "Du verwendest bereits dieselbe oder eine "
                        "neuere Version.",
                    )
                    return False

                self.confirm(
                    f"UPDATE v{remote_version} VERFÜGBAR",
                    f"Installiert: v{VERSION}\n"
                    f"Neu auf GitHub: v{remote_version}\n\n"
                    "Das Update wird automatisch heruntergeladen, "
                    "geprüft und installiert.\n\n"
                    "Danach startet der Uwuntu Image Manager "
                    "automatisch neu.",
                    lambda: self.run_backend(
                        "UWUNTU IMAGE MANAGER UPDATE",
                        [
                            "self-update",
                            "--expected-version",
                            remote_version,
                        ],
                        restart_on_success=True,
                    ),
                )

                return False

            GLib.idle_add(finish)

        threading.Thread(target=worker, daemon=True).start()

    # --------------------------------------------------------
    # Backup
    # --------------------------------------------------------
    def open_backup(self, *_):
        disks = list_disks()

        if not disks:
            self.error(
                "Kein geeigneter Nicht-System-Datenträger wurde gefunden.\n\n"
                "Uwuntu-Stick einstecken und die Funktion erneut öffnen."
            )
            return

        win = ActionWindow(self, "Uwuntu sichern")

        win.root.append(make_label("UWUNTU SICHERN", "card-title"))
        win.root.append(
            make_label(
                "Wähle den eingesteckten Uwuntu-Master-Stick. "
                "Der laufende Ubuntu-Systemdatenträger wird automatisch "
                "ausgeblendet. Erwartet werden Partition 1 = FAT32 und "
                "Partition 2 = ext3 oder ext4.",
                "card-text",
            )
        )

        dropdown = dropdown_from_strings(
            [disk_display(item) for item in disks]
        )
        win.root.append(dropdown)

        note = make_label(
            "Das fertige Image wird automatisch unter "
            f"{IMAGE_DIR} gespeichert.",
            "details",
        )
        win.root.append(note)

        buttons = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=8,
        )
        win.root.append(buttons)

        cancel = Gtk.Button(label="ABBRECHEN")
        cancel.add_css_class("secondary")
        cancel.set_hexpand(True)
        cancel.connect("clicked", lambda *_: win.close())
        buttons.append(cancel)

        start = Gtk.Button(label="BACKUP STARTEN")
        start.add_css_class("primary")
        start.set_hexpand(True)

        def clicked(*_):
            idx = dropdown.get_selected()

            if idx >= len(disks):
                return

            disk = disks[idx]

            self.confirm(
                "BACKUP STARTEN?",
                f"Quelle:\n{disk_display(disk)}\n\n"
                "Der Uwuntu-Stick wird nur gelesen und für das Backup "
                "vorübergehend ausgehängt.",
                lambda: (
                    win.close(),
                    self.run_backend(
                        "UWUNTU SICHERN",
                        ["backup", "--disk", disk["path"]],
                        show_total_time=True,
                    ),
                ),
            )

        start.connect("clicked", clicked)
        buttons.append(start)

        win.present()

    # --------------------------------------------------------
    # Restore
    # --------------------------------------------------------
    def open_restore(self, *_):
        images = image_items()

        if not images:
            self.error(
                "Im Uwuntu-Image-Ordner wurde noch kein gültiges "
                ".uwuntu-Image gefunden."
            )
            return

        disks = list_disks()

        if not disks:
            self.error(
                "Kein geeigneter Ziel-Datenträger wurde gefunden.\n\n"
                "Neue Sticks einstecken und erneut öffnen."
            )
            return

        win = ActionWindow(self, "Uwuntu wiederherstellen")

        win.root.append(
            make_label("UWUNTU WIEDERHERSTELLEN", "card-title")
        )

        win.root.append(
            make_label(
                "Wähle das Image und danach bis zu 10 Zielsticks. Alle "
                "ausgewählten Sticks werden parallel beschrieben. ALLE "
                "Daten auf diesen Zielsticks werden gelöscht. Der laufende "
                "Ubuntu-Datenträger bleibt geschützt.",
                "card-text",
            )
        )

        image_dd = dropdown_from_strings(
            [image_display(item) for item in images]
        )
        win.root.append(image_dd)

        details = make_label(image_details(images[0]), "details")
        win.root.append(details)

        def image_changed(dd, _pspec):
            idx = dd.get_selected()
            if idx < len(images):
                details.set_text(image_details(images[idx]))

        image_dd.connect("notify::selected", image_changed)

        target_title = make_label(
            "ZIELSTICKS AUSWÄHLEN · maximal 10",
            "progress-info",
        )
        win.root.append(target_title)

        target_scroller = Gtk.ScrolledWindow()
        target_scroller.set_policy(
            Gtk.PolicyType.NEVER,
            Gtk.PolicyType.AUTOMATIC,
        )
        target_scroller.set_min_content_height(150)
        target_scroller.set_max_content_height(230)
        win.root.append(target_scroller)

        target_box = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=5,
        )
        target_box.set_margin_top(6)
        target_box.set_margin_bottom(6)
        target_box.set_margin_start(6)
        target_box.set_margin_end(6)
        target_scroller.set_child(target_box)

        checks = []
        selected_label = make_label(
            "0 Sticks ausgewählt",
            "details",
        )

        def update_selected(*_):
            count = sum(1 for check, _disk in checks if check.get_active())
            selected_label.set_text(f"{count} Sticks ausgewählt")

        for disk in disks:
            check = Gtk.CheckButton(label=disk_display(disk))
            check.connect("toggled", update_selected)
            target_box.append(check)
            checks.append((check, disk))

        win.root.append(selected_label)

        warning = make_label(
            "ACHTUNG: Jeder ausgewählte Zielstick wird vollständig gelöscht. "
            "Ein Stick wird erst GRÜN angezeigt, wenn das sichere Auswerfen "
            "vom System bestätigt wurde.",
            "warning",
        )
        win.root.append(warning)

        buttons = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=8,
        )
        win.root.append(buttons)

        cancel = Gtk.Button(label="ABBRECHEN")
        cancel.add_css_class("secondary")
        cancel.set_hexpand(True)
        cancel.connect("clicked", lambda *_: win.close())
        buttons.append(cancel)

        start_button = Gtk.Button(label="PARALLEL-RESTORE STARTEN")
        start_button.add_css_class("primary")
        start_button.set_hexpand(True)

        def clicked(*_):
            image_idx = image_dd.get_selected()
            if image_idx >= len(images):
                return

            selected = [disk for check, disk in checks if check.get_active()]

            if not selected:
                self.error("Bitte mindestens einen Zielstick auswählen.")
                return

            if len(selected) > 10:
                self.error(
                    "Für einen Batch sind maximal 10 Zielsticks vorgesehen."
                )
                return

            image = images[image_idx]
            targets = "\n".join(
                f"Stick {index}: {disk_display(disk)}"
                for index, disk in enumerate(selected, start=1)
            )

            def begin_batch():
                win.close()
                batch = BatchRestoreWindow(self, image, selected)
                self._active_restore_batch = batch
                batch.start()

            self.confirm(
                f"{len(selected)} ZIELSTICK(S) WIRKLICH LÖSCHEN?",
                f"Image:\n{image_display(image)}\n\n"
                f"Ziele:\n{targets}\n\n"
                "Alle ausgewählten Sticks werden gleichzeitig neu "
                "partitioniert und beschrieben. Fertige Sticks dürfen "
                "erst entfernt werden, wenn ihre Zeile GRÜN ist und "
                "'kann jetzt entfernt werden' anzeigt.",
                begin_batch,
            )

        start_button.connect("clicked", clicked)
        buttons.append(start_button)

        win.present()

    # --------------------------------------------------------
    # Ventoy
    # --------------------------------------------------------
    def open_ventoy(self, *_):
        images = image_items()

        if not images:
            self.error(
                "Es wurde noch kein gültiges .uwuntu-Image gefunden."
            )
            return

        roots = find_ventoy_roots()

        if not roots:
            self.error(
                "Kein eingerichteter Uwuntu-Ventoy-Stick wurde gefunden.\n\n"
                "Erwartet werden ventoy/ventoy.json und der Ordner "
                "persistence/."
            )
            return

        win = ActionWindow(self, "Ventoy aktualisieren")

        win.root.append(
            make_label("VENTOY AKTUALISIEREN", "card-title")
        )

        win.root.append(
            make_label(
                "Der Ventoy-Stick muss bereits unter Windows eingerichtet "
                "sein. Dieses Tool ersetzt nur persistence/Uwuntu.dat. "
                "Alle übrigen Ventoy-Dateien bleiben unangetastet.",
                "card-text",
            )
        )

        image_dd = dropdown_from_strings(
            [image_display(item) for item in images]
        )
        win.root.append(image_dd)

        details = make_label(image_details(images[0]), "details")
        win.root.append(details)

        def image_changed(dd, _pspec):
            idx = dd.get_selected()

            if idx < len(images):
                details.set_text(image_details(images[idx]))

        image_dd.connect("notify::selected", image_changed)

        ventoy_dd = dropdown_from_strings(
            [ventoy_display(item) for item in roots]
        )
        win.root.append(ventoy_dd)

        warning = make_label(
            "Nicht verändert: ventoy.json · Theme · Uwuntu.iso · "
            "Windows-ISO · sonstige Ventoy-Einstellungen",
            "warning",
        )
        win.root.append(warning)

        buttons = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=8,
        )
        win.root.append(buttons)

        cancel = Gtk.Button(label="ABBRECHEN")
        cancel.add_css_class("secondary")
        cancel.set_hexpand(True)
        cancel.connect("clicked", lambda *_: win.close())
        buttons.append(cancel)

        start = Gtk.Button(label="VENTOY UPDATE STARTEN")
        start.add_css_class("primary")
        start.set_hexpand(True)

        def clicked(*_):
            image_idx = image_dd.get_selected()
            root_idx = ventoy_dd.get_selected()

            if image_idx >= len(images) or root_idx >= len(roots):
                return

            image = images[image_idx]
            ventoy = roots[root_idx]

            if not ventoy["has_dat"]:
                self.error(
                    "Auf diesem Ventoy-Stick fehlt die vorhandene "
                    "persistence/Uwuntu.dat. Die Ersteinrichtung bleibt "
                    "bewusst dem Windows-PC vorbehalten."
                )
                return

            self.confirm(
                "VENTOY AKTUALISIEREN?",
                f"Image:\n{image_display(image)}\n\n"
                f"Ventoy:\n{ventoy_display(ventoy)}\n\n"
                "Die bisherige Uwuntu.dat wird als "
                "Uwuntu.dat.previous aufbewahrt.",
                lambda: (
                    win.close(),
                    self.run_backend(
                        "VENTOY AKTUALISIEREN",
                        [
                            "ventoy-update",
                            "--image",
                            str(image["path"]),
                            "--ventoy-root",
                            str(ventoy["root"]),
                        ],
                    ),
                ),
            )

        start.connect("clicked", clicked)
        buttons.append(start)

        win.present()

    # --------------------------------------------------------
    # Backend
    # --------------------------------------------------------
    def run_backend(
        self,
        title,
        args,
        restart_on_success=False,
        show_total_time=False,
    ):
        progress = ProgressWindow(self, title)

        command = [
            "sudo",
            "-n",
            ROOT_HELPER,
            *args,
        ]

        def worker():
            final_success = None
            final_detail = ""
            final_error = None
            backend_restart = False

            try:
                proc = subprocess.Popen(
                    command,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                )

                for line in proc.stdout:
                    line = line.strip()

                    if not line:
                        continue

                    try:
                        event = json.loads(line)
                    except Exception:
                        continue

                    if event.get("type") == "success":
                        final_success = event.get("message", "Fertig.")
                        final_detail = event.get("detail", "") or ""
                        backend_restart = bool(
                            event.get("restart", False)
                        )
                    elif event.get("type") == "error":
                        final_error = event.get("message", "Unbekannter Fehler.")

                    GLib.idle_add(progress.handle_event, event)

                rc = proc.wait()

                if rc != 0 and not final_error:
                    final_error = (
                        "Der Vorgang wurde mit einem Fehler beendet. "
                        "Details stehen im Log."
                    )

            except Exception as exc:
                final_error = str(exc)

            def finish_ui():
                elapsed_seconds = max(
                    0.0,
                    time.monotonic() - progress.operation_started,
                )
                progress.close()

                if final_error:
                    self.error(final_error)
                elif restart_on_success and backend_restart:
                    launcher = (
                        HOME
                        / ".local/bin/uwuntu-image-manager"
                    )

                    try:
                        subprocess.Popen(
                            [str(launcher)],
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                            start_new_session=True,
                        )
                    except Exception as exc:
                        self.error(
                            "Update wurde installiert, aber der "
                            "automatische Neustart ist fehlgeschlagen.\n\n"
                            f"{exc}\n\n"
                            "Bitte den Uwuntu Image Manager einmal "
                            "manuell neu öffnen."
                        )
                        return False

                    app = self.get_application()
                    if app:
                        app.quit()
                else:
                    detail = final_detail or (
                        "Der Datenträger kann nach erfolgreichem "
                        "Backup/Restore sicher entfernt werden."
                    )

                    if show_total_time:
                        detail = (
                            f"Gesamtdauer: {fmt_duration(elapsed_seconds)}\n\n"
                            + detail
                        )

                    self.info(
                        final_success or "Vorgang abgeschlossen.",
                        detail,
                    )

                return False

            GLib.idle_add(finish_ui)

        threading.Thread(target=worker, daemon=True).start()


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID)

    def do_activate(self):
        window = self.props.active_window

        if not window:
            window = MainWindow(self)

        window.present()


if __name__ == "__main__":
    app = App()
    raise SystemExit(app.run(sys.argv))
PYAPP

    chmod 0755 "$USER_APP_DIR/uwuntu_image_manager.py"

    cat > "$USER_BIN_DIR/uwuntu-image-manager" <<EOF
#!/usr/bin/env bash
exec python3 "$USER_APP_DIR/uwuntu_image_manager.py" "\$@"
EOF

    chmod 0755 "$USER_BIN_DIR/uwuntu-image-manager"

    # --------------------------------------------------------
    # Eigenes Icon
    # --------------------------------------------------------
    cat > "$USER_ICON_DIR/uwuntu-image-manager.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#20242c"/>
      <stop offset="1" stop-color="#101216"/>
    </linearGradient>
    <linearGradient id="blue" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#75b7ff"/>
      <stop offset="1" stop-color="#5aa2ff"/>
    </linearGradient>
  </defs>

  <rect x="12" y="12" width="232" height="232" rx="48" fill="url(#bg)" stroke="#343b48" stroke-width="8"/>

  <path d="M74 70v70c0 33 20 52 54 52s54-19 54-52V70"
        fill="none" stroke="#f4f4f5" stroke-width="20" stroke-linecap="round"/>

  <path d="M182 58l22 22-22 22" fill="none" stroke="#f5a623"
        stroke-width="13" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M204 80h-43" fill="none" stroke="#f5a623"
        stroke-width="13" stroke-linecap="round"/>

  <path d="M74 198l-22-22 22-22" fill="none" stroke="url(#blue)"
        stroke-width="13" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M52 176h43" fill="none" stroke="url(#blue)"
        stroke-width="13" stroke-linecap="round"/>

  <circle cx="128" cy="128" r="12" fill="#61d36b"/>
</svg>
SVG

    # --------------------------------------------------------
    # Desktop-Datei
    # --------------------------------------------------------
    cat > "$USER_APPLICATIONS/com.uwuntu.ImageManager.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Uwuntu Image Manager
Comment=Uwuntu sichern, wiederherstellen und Ventoy aktualisieren
Exec=$USER_BIN_DIR/uwuntu-image-manager
Icon=uwuntu-image-manager
Terminal=false
StartupNotify=true
StartupWMClass=com.uwuntu.ImageManager
Categories=Utility;System;
EOF

    chmod 0755 "$USER_APPLICATIONS/com.uwuntu.ImageManager.desktop"

    # Desktop-Verzeichnis ermitteln
    DESKTOP_DIR="$(
        sudo -u "$REAL_USER" \
            HOME="$REAL_HOME" \
            xdg-user-dir DESKTOP 2>/dev/null || true
    )"

    if [[ -z "$DESKTOP_DIR" ]]; then
        if [[ -d "$REAL_HOME/Schreibtisch" ]]; then
            DESKTOP_DIR="$REAL_HOME/Schreibtisch"
        else
            DESKTOP_DIR="$REAL_HOME/Desktop"
        fi
    fi

    mkdir -p "$DESKTOP_DIR"

    cp \
        "$USER_APPLICATIONS/com.uwuntu.ImageManager.desktop" \
        "$DESKTOP_DIR/Uwuntu Image Manager.desktop"

    chmod 0755 "$DESKTOP_DIR/Uwuntu Image Manager.desktop"

    # Den früheren, nicht zur Gtk.Application-ID passenden Launcher entfernen.
    rm -f "$USER_APPLICATIONS/uwuntu-image-manager.desktop"

    chown -R "$REAL_USER":"$(id -gn "$REAL_USER")" \
        "$USER_APP_DIR" \
        "$USER_BIN_DIR/uwuntu-image-manager" \
        "$USER_APPLICATIONS/com.uwuntu.ImageManager.desktop" \
        "$REAL_HOME/.local/share/icons" \
        "$USER_STATE_DIR" \
        "$USER_IMAGE_DIR" \
        "$DESKTOP_DIR/Uwuntu Image Manager.desktop"

    # Desktop-Verknüpfung nach Möglichkeit direkt als vertrauenswürdig markieren.
    sudo -u "$REAL_USER" \
        HOME="$REAL_HOME" \
        gio set \
            "$DESKTOP_DIR/Uwuntu Image Manager.desktop" \
            metadata::trusted true \
            >/dev/null 2>&1 || true

    update-desktop-database "$USER_APPLICATIONS" >/dev/null 2>&1 || true
    sudo -u "$REAL_USER" \
        HOME="$REAL_HOME" \
        gtk-update-icon-cache "$REAL_HOME/.local/share/icons/hicolor" \
        >/dev/null 2>&1 || true

    echo
    echo "============================================================"
    echo " Uwuntu Image Manager v$APP_VERSION installiert"
    echo "============================================================"
    echo
    echo "Desktop:"
    echo "  $DESKTOP_DIR/Uwuntu Image Manager.desktop"
    echo
    echo "Images:"
    echo "  $USER_IMAGE_DIR"
    echo
    echo "Root-Helfer:"
    echo "  $ROOT_HELPER"
    echo
    echo "Der Image Manager benötigt nach dieser Installation"
    echo "für seine eigenen Root-Aktionen kein Sudo-Passwort mehr."
    echo

    exit 0
fi

# ============================================================
# NORMALER INSTALLER-START
# ============================================================

echo
echo "============================================================"
echo " Uwuntu Image Manager v$APP_VERSION"
echo "============================================================"
echo
echo "Installiert:"
echo "  • grafische Oberfläche"
echo "  • Desktop-Verknüpfung"
echo "  • eigenes Uwuntu-Icon"
echo "  • Image-Ordner ~/Uwuntu-Images"
echo "  • benötigte Linux-Pakete"
echo "  • begrenzten Root-Helfer für Backup/Restore/Ventoy"
echo
echo "Für die EINMALIGE Installation kann Ubuntu jetzt nach"
echo "deinem Benutzerpasswort fragen."
echo
echo "Danach benötigt der Uwuntu Image Manager für seine"
echo "eigenen Funktionen kein Passwort mehr."
echo

SCRIPT="$(readlink -f "$0")"

if command -v pkexec >/dev/null 2>&1; then
    pkexec env \
        PATH="$PATH" \
        bash "$SCRIPT" \
        --root-install "$REAL_USER" "$REAL_HOME"
else
    sudo bash "$SCRIPT" \
        --root-install "$REAL_USER" "$REAL_HOME"
fi

echo
echo "Installation abgeschlossen."
echo "Du kannst den 'Uwuntu Image Manager' jetzt per Doppelklick"
echo "über die neue Desktop-Verknüpfung starten."
echo
read -r -p "ENTER zum Schließen ..." _ || true
