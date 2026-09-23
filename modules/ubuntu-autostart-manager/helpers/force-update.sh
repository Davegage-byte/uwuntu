#!/usr/bin/env bash
set -u

STARTUP_CHECK_MODE=0
if [ "${1:-}" = "--startup-check" ]; then
    STARTUP_CHECK_MODE=1
fi

if [ "$STARTUP_CHECK_MODE" -eq 1 ]; then
    REF_RETRY=0
    REF_CONNECT_TIMEOUT=2
    REF_MAX_TIME=3
    DOWNLOAD_RETRY=0
    DOWNLOAD_CONNECT_TIMEOUT=2
    DOWNLOAD_MAX_TIME=4
else
    REF_RETRY=1
    REF_CONNECT_TIMEOUT=6
    REF_MAX_TIME=15
    DOWNLOAD_RETRY=2
    DOWNLOAD_CONNECT_TIMEOUT=8
    DOWNLOAD_MAX_TIME=45
fi

RAW_URL="https://raw.githubusercontent.com/Davegage-byte/uwuntu/refs/heads/main/Ubuntu%20Autostart%20Manager.sh"
REF_API_URL="https://api.github.com/repos/Davegage-byte/uwuntu/git/ref/heads/main"
RAW_COMMIT_BASE="https://raw.githubusercontent.com/Davegage-byte/uwuntu"
RAW_MANAGER_PATH="Ubuntu%20Autostart%20Manager.sh"
RAW_MANIFEST_PATH="modules/ubuntu-autostart-manager/manifest.json"
PATH_FILE="$HOME/.config/uwuntu-manager-path"
DEFAULT_TARGET="$HOME/.local/bin/Ubuntu Autostart Manager.sh"
LOG="$HOME/uwuntu_force_update.log"
KIOSK="$HOME/.local/bin/start-kiosk-apps.sh"
CLOSE_APPS="$HOME/.local/bin/close-diagnostic-apps.sh"
LOCAL_MANIFEST="$HOME/.local/share/uwuntu/runtime-manifest.json"
LOCAL_SOURCE_REF="$HOME/.local/share/uwuntu/source-ref"
STATUS_PIPE_ACTIVE=1

status() {
    # Solange Hardware Check lebt, bekommt dessen Update-Fenster STATUS-Zeilen.
    # Vor dem Diagnose-Shutdown wird diese Pipe bewusst abgeschaltet, damit
    # der Updater nach dem Beenden von Hardware Check keinen SIGPIPE /
    # Broken-Pipe-Abbruch mehr bekommen kann.
    if [ "${STATUS_PIPE_ACTIVE:-0}" -eq 1 ]; then
        printf 'STATUS|%s\n' "$1" 2>/dev/null || true
    fi
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG" 2>/dev/null || true
}

fail() {
    status "FEHLER: $1"
    exit "${2:-1}"
}

startup_skip() {
    status "$1"
    exit 0
}

remember_source_ref() {
    [ -n "${latest_sha:-}" ] || return 0
    mkdir -p "$(dirname "$LOCAL_SOURCE_REF")" 2>/dev/null || true
    printf '%s\n' "$latest_sha" > "$LOCAL_SOURCE_REF" 2>/dev/null || true
}

# Neue Installationen verwenden immer den festen Pfad. Für eine ältere
# Installation lesen wir die bisherige Pfaddatei nur noch als Fallback.
TARGET="$DEFAULT_TARGET"
if [ ! -f "$TARGET" ] && [ -f "$PATH_FILE" ]; then
    legacy_target="$(cat "$PATH_FILE" 2>/dev/null || true)"
    if [ -n "$legacy_target" ] && [ -f "$legacy_target" ]; then
        TARGET="$legacy_target"
    fi
fi

[ -f "$TARGET" ] || fail "Ubuntu Autostart Manager wurde nicht gefunden." 12
printf '%s\n' "$TARGET" > "$PATH_FILE" 2>/dev/null || true
command -v curl >/dev/null 2>&1 || fail "curl ist nicht installiert." 13

if [ "$STARTUP_CHECK_MODE" -eq 1 ]; then
    status "Prüfe GitHub vor dem Programmstart …"
else
    status "Suche frisch auf GitHub nach Update …"
fi

TMP="$(mktemp /tmp/uwuntu-manager-update.XXXXXX.sh)" || fail "Temporäre Datei konnte nicht erstellt werden." 14
REF_TMP="$(mktemp /tmp/uwuntu-manager-ref.XXXXXX.json)" || fail "Temporäre GitHub-Ref-Datei konnte nicht erstellt werden." 15
MANIFEST_TMP="$(mktemp /tmp/uwuntu-runtime-manifest.XXXXXX.json)" || fail "Temporäre Manifest-Datei konnte nicht erstellt werden." 16
BACKUP="${TARGET}.update-backup"
trap 'rm -f "$TMP" "$REF_TMP" "$MANIFEST_TMP" "${TARGET}.new" 2>/dev/null || true' EXIT

# Jeder Druck auf U muss GitHub wirklich neu abfragen.
# Zuerst wird der aktuelle Commit-SHA von main über die GitHub-API ermittelt.
# Anschließend laden wir die Manager-Datei an GENAU diesem Commit. Damit
# umgehen wir zusätzlich eine mögliche kurze Verzögerung bei der beweglichen
# main-RAW-Weitergabe. Wenn die API einmal nicht verfügbar/rate-limited ist,
# bleibt der bisherige main-RAW-Weg als Fallback erhalten.
CACHE_BUST="$(date +%s%N)-$$"
DOWNLOAD_URL="$RAW_URL"
MANIFEST_DOWNLOAD_URL="${RAW_COMMIT_BASE}/main/${RAW_MANIFEST_PATH}"
latest_sha=""

if curl \
    --fail \
    --location \
    --silent \
    --show-error \
    --retry "$REF_RETRY" \
    --retry-delay 1 \
    --connect-timeout "$REF_CONNECT_TIMEOUT" \
    --max-time "$REF_MAX_TIME" \
    --header 'Accept: application/vnd.github+json' \
    --header 'Cache-Control: no-cache, no-store, max-age=0' \
    --header 'Pragma: no-cache' \
    --output "$REF_TMP" \
    "${REF_API_URL}?uwuntu_cache_bust=${CACHE_BUST}"
then
    latest_sha="$(
        python3 - "$REF_TMP" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        data = json.load(handle)
    value = str(data.get("object", {}).get("sha", "")).strip()
    if len(value) == 40 and all(ch in "0123456789abcdefABCDEF" for ch in value):
        print(value)
except Exception:
    pass
PY
    )"

    if [ -n "$latest_sha" ]; then
        DOWNLOAD_URL="${RAW_COMMIT_BASE}/${latest_sha}/${RAW_MANAGER_PATH}"
        MANIFEST_DOWNLOAD_URL="${RAW_COMMIT_BASE}/${latest_sha}/${RAW_MANIFEST_PATH}"
        printf '%s  GitHub main Commit: %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$latest_sha" >> "$LOG" 2>/dev/null || true

        if [ "$STARTUP_CHECK_MODE" -eq 1 ] \
            && [ -f "$LOCAL_SOURCE_REF" ] \
            && [ "$(cat "$LOCAL_SOURCE_REF" 2>/dev/null || true)" = "$latest_sha" ]
        then
            status "Bereits aktuell"
            exit 0
        fi
    else
        if [ "$STARTUP_CHECK_MODE" -eq 1 ]; then
            startup_skip "GitHub-Antwort nicht eindeutig · starte lokalen Stand"
        fi

        printf '%s  GitHub-Ref konnte nicht ausgewertet werden · RAW-main-Fallback\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG" 2>/dev/null || true
    fi
else
    if [ "$STARTUP_CHECK_MODE" -eq 1 ]; then
        startup_skip "GitHub nicht schnell erreichbar · starte lokalen Stand"
    fi

    printf '%s  GitHub-Ref-API nicht verfügbar · RAW-main-Fallback\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG" 2>/dev/null || true
fi

download_runtime_manifest() {
    curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry "$DOWNLOAD_RETRY" \
        --retry-delay 1 \
        --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" \
        --max-time "$DOWNLOAD_MAX_TIME" \
        --header 'Cache-Control: no-cache, no-store, max-age=0' \
        --header 'Pragma: no-cache' \
        --output "$MANIFEST_TMP" \
        "${MANIFEST_DOWNLOAD_URL}?uwuntu_cache_bust=${CACHE_BUST}"
}

download_manager() {
    curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry "$DOWNLOAD_RETRY" \
        --retry-delay 1 \
        --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" \
        --max-time "$DOWNLOAD_MAX_TIME" \
        --header 'Cache-Control: no-cache, no-store, max-age=0' \
        --header 'Pragma: no-cache' \
        --output "$TMP" \
        "${DOWNLOAD_URL}?uwuntu_cache_bust=${CACHE_BUST}"
}

if [ "$STARTUP_CHECK_MODE" -eq 1 ]; then
    # Wenn main sich geändert hat, Manager und Manifest parallel laden.
    # So addieren sich schlechte WLAN-Timeouts beim Boot nicht.
    download_runtime_manifest &
    manifest_pid=$!
    download_manager &
    manager_pid=$!

    manifest_rc=0
    manager_rc=0
    wait "$manifest_pid" || manifest_rc=$?
    wait "$manager_pid" || manager_rc=$?

    if [ "$manifest_rc" -ne 0 ] || [ "$manager_rc" -ne 0 ]; then
        startup_skip "GitHub nicht schnell erreichbar · starte lokalen Stand"
    fi
else
    if ! download_runtime_manifest; then
        fail "Runtime-Manifest konnte nicht von GitHub geladen werden." 25
    fi

    if ! download_manager; then
        fail "GitHub ist nicht erreichbar oder der Download ist fehlgeschlagen." 20
    fi
fi
[ -s "$TMP" ] || fail "GitHub hat eine leere Datei geliefert." 21
head -n 1 "$TMP" | grep -q '^#!/usr/bin/env bash' \
    || fail "Die heruntergeladene Datei ist kein gültiger Uwuntu-Manager." 22
grep -q '^main_menu()' "$TMP" \
    || fail "Die heruntergeladene Datei ist unvollständig." 23
bash -n "$TMP" >/dev/null 2>&1 \
    || fail "Die heruntergeladene Datei hat einen Syntaxfehler." 24

validate_runtime_manifest() {
    python3 - "$1" <<'PY'
import json
import re
import sys

expected = ("network_check", "wipe_auto", "hardware_check", "camera_test", "audio_test")
try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if data.get("schema") != 1 or isinstance(data.get("runtime_build"), bool):
        raise ValueError
    if not isinstance(data.get("runtime_build"), int) or data["runtime_build"] <= 0:
        raise ValueError
    components = data.get("components")
    if not isinstance(components, dict) or any(name not in components for name in expected):
        raise ValueError
    if any(not isinstance(components[name], str) or
           not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", components[name])
           for name in expected):
        raise ValueError
except (OSError, UnicodeError, json.JSONDecodeError, ValueError, TypeError):
    raise SystemExit(1)
PY
}

runtime_build() {
    python3 - "$1" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    print(json.load(handle)["runtime_build"])
PY
}

runtime_manifests_equal() {
    python3 - "$1" "$2" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as first:
    left = json.load(first)
with open(sys.argv[2], "r", encoding="utf-8") as second:
    right = json.load(second)
raise SystemExit(0 if left == right else 1)
PY
}

validate_runtime_manifest "$MANIFEST_TMP" \
    || fail "Remote-Runtime-Manifest ist ungültig." 26

manager_update_needed=0
runtime_update_needed=0

local_build="$(grep -m1 '^MANAGER_BUILD=[0-9][0-9]*$' "$TARGET" 2>/dev/null | cut -d= -f2 || true)"
remote_build="$(grep -m1 '^MANAGER_BUILD=[0-9][0-9]*$' "$TMP" 2>/dev/null | cut -d= -f2 || true)"

# Ab dieser Version besitzt der Manager eine monotone Buildnummer.
# Fehlt sie auf GitHub, ist dort definitiv noch die ältere Generation.
if [ -n "$local_build" ] && [ -z "$remote_build" ]; then
    status "GitHub-Manager ist älter · kein Manager-Downgrade"
elif [ -n "$local_build" ] && [ -n "$remote_build" ] \
    && [ "$remote_build" -lt "$local_build" ]; then
    status "GitHub-Manager ist älter · kein Manager-Downgrade"
elif ! cmp -s "$TARGET" "$TMP"; then
    manager_update_needed=1
fi

remote_runtime_build="$(runtime_build "$MANIFEST_TMP")"
if [ ! -e "$LOCAL_MANIFEST" ]; then
    runtime_update_needed=1
    status "Lokales Runtime-Manifest fehlt · Runtime-Installation erforderlich"
else
    validate_runtime_manifest "$LOCAL_MANIFEST" \
        || fail "Lokales Runtime-Manifest ist ungültig; Update wird sicher abgebrochen." 27
    local_runtime_build="$(runtime_build "$LOCAL_MANIFEST")"
    if [ "$remote_runtime_build" -gt "$local_runtime_build" ]; then
        runtime_update_needed=1
    elif [ "$remote_runtime_build" -lt "$local_runtime_build" ]; then
        fail "Remote-Runtime ist älter als die installierte Runtime (Build $remote_runtime_build < $local_runtime_build). Update wird abgebrochen, um einen Downgrade zu verhindern." 29
    elif ! runtime_manifests_equal "$LOCAL_MANIFEST" "$MANIFEST_TMP"; then
        fail "Runtime-Manifest geändert, aber runtime_build nicht erhöht." 28
    fi
fi

if [ "$manager_update_needed" -eq 0 ] && [ "$runtime_update_needed" -eq 0 ]; then
    remember_source_ref
    status "Bereits aktuell"
    exit 0
fi

status "Update gefunden · Manager=${manager_update_needed} Runtime=${runtime_update_needed}"

if [ "$manager_update_needed" -eq 1 ]; then
    rm -f "$BACKUP" 2>/dev/null || true
    cp -a "$TARGET" "$BACKUP" \
        || fail "Sicherung der bisherigen Version fehlgeschlagen." 30

    chmod +x "$TMP" || true
    cp "$TMP" "${TARGET}.new" \
        || fail "Neue Manager-Datei konnte nicht vorbereitet werden." 31
    chmod +x "${TARGET}.new" || true
    mv -f "${TARGET}.new" "$TARGET" \
        || fail "Ubuntu Autostart Manager konnte nicht ersetzt werden." 32
fi

status "Installiere Uwuntu-Komponenten …"

# Manager und Module muessen aus exakt demselben Stand stammen. Wenn die
# Ref-API nicht ausgewertet werden konnte, wird der bereits protokollierte
# RAW-main-Fallback konsistent auch fuer alle Module verwendet.
if ! UWUNTU_SOURCE_REF="${latest_sha:-main}" "$TARGET" --apply-update >> "$LOG" 2>&1; then
    if [ "$manager_update_needed" -eq 1 ]; then
        cp -a "$BACKUP" "$TARGET" 2>/dev/null || true
        chmod +x "$TARGET" 2>/dev/null || true
        fail "Installation fehlgeschlagen · vorherige Manager-Version wiederhergestellt." 40
    fi
    fail "Runtime-Installation fehlgeschlagen · Manager blieb unverändert." 40
fi

[ "$manager_update_needed" -eq 0 ] || rm -f "$BACKUP" 2>/dev/null || true
remember_source_ref

if [ "$STARTUP_CHECK_MODE" -eq 1 ]; then
    # Beim Boot laufen noch keine Diagnoseprogramme. Der Kiosk-Launcher
    # führt sich nach Code 10 genau einmal aus dem frisch installierten
    # Stand neu aus und startet erst danach die eigentlichen Apps.
    status "Update erfolgreich · neuer Stand startet …"
    exit 10
fi

status "Update erfolgreich · Anwendungen werden neu gestartet …"

# Status noch kurz sichtbar lassen.
sleep 0.7

# KRITISCH: Ab hier darf der Updater keinerlei Abhängigkeit mehr vom alten
# Hardware-Check-Prozess haben. force_update_worker() liest unsere stdout-Pipe.
# Sobald HC vom Close-Helper beendet wird, verschwindet deren Leseseite.
# Deshalb Status-Pipe vorher deaktivieren und stdin/stdout/stderr vollständig
# auf /dev/null bzw. die Logdatei umhängen.
STATUS_PIPE_ACTIVE=0
exec </dev/null >>"$LOG" 2>&1

echo "$(date '+%Y-%m-%d %H:%M:%S')  Neustartphase vom Hardware Check entkoppelt."

# Ab dieser Generation nicht mehr zwei verschiedene Schließlogiken pflegen:
# Der zentrale STRG+Q-Helper kennt alle aktuellen Wrapper, Cache-Prozesse und
# besitzt bereits TERM-Wiederholung + KILL-Fallback.
if [ -x "$CLOSE_APPS" ]; then
    # Der Force-Updater ist ein Kind des Hardware-Check-Prozesses.
    # Ohne Schutz würde der zentrale Close-Helper ihn zusammen mit HC beenden
    # und die anschließenden Restart-Zeilen nie erreichen.
    UWUNTU_KEEP_PID="$$" "$CLOSE_APPS" >> "$LOG" 2>&1 || true
else
    # Fallback für sehr alte/teilweise Installationen.
    pkill -TERM -f '/tmp/network-check-' 2>/dev/null || true
    pkill -TERM -f '/tmp/wipe-auto-' 2>/dev/null || true
    pkill -TERM -f '/tmp/hardware-check\.' 2>/dev/null || true

    for pattern in         '/.local/bin/uwuntu-camera-test.sh'         '/.cache/uwuntu-camera-test/'         'uwuntu-camera-test-python'         '/.local/bin/uwuntu-touch-tester.sh'         'uwuntu-touch-tester-python'         '/.local/bin/uwuntu-display-test.sh'         'uwuntu-display-test-python'         '/.local/bin/uwuntu-audio-test.sh'         '/.cache/uwuntu-audio-test/'         'uwuntu-audio-test-python'
    do
        pkill -TERM -f "$pattern" 2>/dev/null || true
    done

    pkill -TERM -x snapshot 2>/dev/null || true
    sleep 0.35

    # Kamera/Audio notfalls hart schließen, damit der anschließende Kiosk nicht
    # parallel zu einer alten Instanz startet.
    pkill -KILL -f '/.cache/uwuntu-camera-test/' 2>/dev/null || true
    pkill -KILL -f 'uwuntu-camera-test-python' 2>/dev/null || true
    pkill -KILL -f '/.cache/uwuntu-audio-test/' 2>/dev/null || true
    pkill -KILL -f 'uwuntu-audio-test-python' 2>/dev/null || true
fi

# Den alten Prozessen etwas Zeit geben, vollständig aus Mutter/AT-SPI zu
# verschwinden, bevor das neue Tiling-Layout ausgelöst wird.
sleep 0.8

if [ -x "$KIOSK" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S')  Starte Diagnose-Kiosk in eigener Session …"

    # Eigene Session: Der Kiosk überlebt das Ende dieses Update-Helfers sicher
    # und ist weder an Hardware Check noch an dessen früheres stdout gebunden.
    if command -v setsid >/dev/null 2>&1; then
        nohup setsid "$KIOSK" >> "$LOG" 2>&1 </dev/null &
    else
        nohup "$KIOSK" >> "$LOG" 2>&1 </dev/null &
    fi
    KIOSK_PID=$!

    sleep 0.4
    if kill -0 "$KIOSK_PID" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S')  Diagnose-Kiosk gestartet · PID $KIOSK_PID"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S')  WARNUNG: Kiosk-Prozess ist direkt wieder beendet."
    fi
else
    # Fallback, falls nur die Einzelprogramme installiert sind.
    echo "$(date '+%Y-%m-%d %H:%M:%S')  Kiosk-Launcher fehlt · starte Einzelprogramme als Fallback."

    [ -x "$HOME/.local/bin/network-check.sh" ] \
        && nohup "$HOME/.local/bin/network-check.sh" >> "$LOG" 2>&1 </dev/null &
    [ -x "$HOME/.local/bin/uwuntu-camera-test.sh" ] \
        && nohup "$HOME/.local/bin/uwuntu-camera-test.sh" >> "$LOG" 2>&1 </dev/null &
    [ -x "$HOME/.local/bin/uwuntu-audio-test.sh" ] \
        && nohup "$HOME/.local/bin/uwuntu-audio-test.sh" >> "$LOG" 2>&1 </dev/null &
    [ -x "$HOME/.local/bin/hardware-check.sh" ] \
        && nohup "$HOME/.local/bin/hardware-check.sh" >> "$LOG" 2>&1 </dev/null &
fi

exit 0
