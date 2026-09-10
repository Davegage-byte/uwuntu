#!/usr/bin/env bash
set -u

# ============================================================
# Ubuntu / GNOME Autostart Manager + 4-Tile Diagnose-Kiosk + Network Check v2.28 + Hardware Check v4.5.72 + Wipe Auto v3.32 + Audio Test v1.20
# ============================================================

USER_AUTOSTART="$HOME/.config/autostart"
SYSTEM_AUTOSTART="/etc/xdg/autostart"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
# Neuer 4-Felder-Kiosk
KIOSK_DESKTOP="$USER_AUTOSTART/diagnostic-4tile-kiosk.desktop"
OLD_KIOSK_DESKTOP="$USER_AUTOSTART/firefox-snapshot-kiosk.desktop"
KIOSK_LAUNCHER="$BIN_DIR/start-kiosk-apps.sh"

NETWORK_CHECK_SCRIPT="$BIN_DIR/network-check.sh"
NETWORK_CHECK_APP_DESKTOP="$APP_DIR/com.david.NetworkCheck.desktop"
NETWORK_CHECK_AUTOSTART="$USER_AUTOSTART/com.david.NetworkCheck.desktop"

WIPE_AUTO_SCRIPT="$BIN_DIR/wipe-auto-app.sh"
# Standalone-Wipe bekommt einen eigenen Desktop-Eintrag. Der historische
# com.david.WipeAuto.desktop-Slot bleibt ausschließlich für den Audio Test,
# damit das vorhandene Tiling-Assistant-Layout stabil bleibt.
WIPE_AUTO_APP_DESKTOP="$APP_DIR/com.david.WipeAutoStandalone.desktop"
AUDIO_TEST_SCRIPT="$BIN_DIR/uwuntu-audio-test.sh"
AUDIO_TEST_APP_DESKTOP="$APP_DIR/com.david.WipeAuto.desktop"
HARDWARE_CHECK_SCRIPT="$BIN_DIR/hardware-check.sh"
HARDWARE_CHECK_APP_DESKTOP="$APP_DIR/com.david.HardwareCheck.desktop"
CAMERA_TEST_SCRIPT="$BIN_DIR/uwuntu-camera-test.sh"
# Eigene Desktop-ID für den Uwuntu-Kamera-Test. Der alte Snapshot-Override
# wird bei der Installation gezielt entfernt, damit keine veraltete Zuordnung bleibt.
CAMERA_TEST_APP_DESKTOP="$APP_DIR/com.david.UwuntuCameraTest.desktop"
CAMERA_TEST_LEGACY_DESKTOP="$APP_DIR/org.gnome.Snapshot.desktop"
TOUCH_TEST_SCRIPT="$BIN_DIR/uwuntu-touch-tester.sh"
TOUCH_STATE_FILE="$HOME/.local/state/uwuntu/touch_tester_status.json"
DISPLAY_TEST_SCRIPT="$BIN_DIR/uwuntu-display-test.sh"
DISPLAY_STATE_FILE="$HOME/.local/state/uwuntu/display_test_status.json"
CLOSE_APPS_SCRIPT="$BIN_DIR/close-diagnostic-apps.sh"
FORCE_UPDATE_SCRIPT="$BIN_DIR/uwuntu-force-update.sh"
MANAGER_PATH_FILE="$HOME/.config/uwuntu-manager-path"
MANAGER_INSTALL_PATH="$BIN_DIR/Ubuntu Autostart Manager.sh"

# Interne Buildnummer für den manuellen GitHub-Updater.
# Verhindert, dass U versehentlich eine ältere GitHub-Fassung installiert.
MANAGER_BUILD=2026090906
AUTO_MODE=0

mkdir -p "$USER_AUTOSTART" "$BIN_DIR" "$APP_DIR" "$HOME/.config"

pause() {
    if [ "${AUTO_MODE:-0}" -eq 1 ]; then
        return 0
    fi
    echo
    read -r -p "ENTER zum Fortfahren ..." _
}
header() {
    clear 2>/dev/null || true
    echo "============================================================"
    echo " Ubuntu Autostart Manager"
    echo "============================================================"
    echo
}

desktop_name() {
    local file="$1"
    local name
    name="$(grep -m1 '^Name=' "$file" 2>/dev/null | cut -d= -f2-)"
    [ -n "$name" ] || name="$(basename "$file")"
    printf '%s' "$name"
}
desktop_exec() {
    local file="$1"
    grep -m1 '^Exec=' "$file" 2>/dev/null | cut -d= -f2-
}

is_hidden() {
    local file="$1"
    grep -qiE '^Hidden=true$' "$file" 2>/dev/null
}

gnome_disabled() {
    local file="$1"
    grep -qiE '^X-GNOME-Autostart-enabled=false$' "$file" 2>/dev/null
}
# Ermittelt den effektiven Zustand eines Desktop-Autostarts.
# User-Datei mit gleichem Dateinamen überschreibt System-Datei.
effective_state() {
    local base="$1"
    local userfile="$USER_AUTOSTART/$base"
    local systemfile="$SYSTEM_AUTOSTART/$base"

    if [ -f "$userfile" ]; then
        if is_hidden "$userfile" || gnome_disabled "$userfile"; then
            echo "DEAKTIVIERT"
        else
            echo "AKTIV"
        fi
        return
    fi
    if [ -f "$systemfile" ]; then
        if is_hidden "$systemfile" || gnome_disabled "$systemfile"; then
            echo "DEAKTIVIERT"
        else
            echo "AKTIV"
        fi
        return
    fi

    echo "UNBEKANNT"
}

build_autostart_index() {
    AUTOSTART_FILES=()
    AUTOSTART_BASES=()

    declare -A seen=()
    # User-Dateien zuerst
    shopt -s nullglob
    for f in "$USER_AUTOSTART"/*.desktop; do
        localbase="$(basename "$f")"
        if [ -z "${seen[$localbase]+x}" ]; then
            seen["$localbase"]=1
            AUTOSTART_BASES+=("$localbase")
        fi
    done
    # System-Dateien ergänzen
    if [ -d "$SYSTEM_AUTOSTART" ]; then
        for f in "$SYSTEM_AUTOSTART"/*.desktop; do
            localbase="$(basename "$f")"
            if [ -z "${seen[$localbase]+x}" ]; then
                seen["$localbase"]=1
                AUTOSTART_BASES+=("$localbase")
            fi
        done
    fi
    shopt -u nullglob
    # Alphabetisch sortieren
    if [ "${#AUTOSTART_BASES[@]}" -gt 0 ]; then
        mapfile -t AUTOSTART_BASES < <(printf '%s\n' "${AUTOSTART_BASES[@]}" | sort)
    fi
}

show_autostarts() {
    build_autostart_index

    echo "GNOME/XDG AUTOSTARTS"
    echo "------------------------------------------------------------"

    if [ "${#AUTOSTART_BASES[@]}" -eq 0 ]; then
        echo "Keine Autostart-Einträge gefunden."
        return
    fi
    printf "%-4s %-12s %-10s %-38s %s\n" "Nr." "Status" "Quelle" "Name" "Datei"
    printf "%-4s %-12s %-10s %-38s %s\n" "----" "------------" "----------" "--------------------------------------" "----------------"

    local i=1
    local base userfile systemfile source displayfile name state

    for base in "${AUTOSTART_BASES[@]}"; do
        userfile="$USER_AUTOSTART/$base"
        systemfile="$SYSTEM_AUTOSTART/$base"
        if [ -f "$userfile" ]; then
            displayfile="$userfile"
            if [ -f "$systemfile" ]; then
                source="Override"
            else
                source="Benutzer"
            fi
        else
            displayfile="$systemfile"
            source="System"
        fi

        name="$(desktop_name "$displayfile")"
        state="$(effective_state "$base")"

        printf "%-4s %-12s %-10s %-38.38s %s\n" \
            "$i" "$state" "$source" "$name" "$base"
        i=$((i + 1))
    done
}

choose_autostart() {
    build_autostart_index
    show_autostarts
    echo

    if [ "${#AUTOSTART_BASES[@]}" -eq 0 ]; then
        return 1
    fi

    local num
    read -r -p "Nummer auswählen (0 = Abbrechen): " num

    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        echo "Ungültige Eingabe."
        return 1
    fi

    if [ "$num" -eq 0 ]; then
        return 1
    fi
    if [ "$num" -lt 1 ] || [ "$num" -gt "${#AUTOSTART_BASES[@]}" ]; then
        echo "Nummer außerhalb des Bereichs."
        return 1
    fi

    SELECTED_BASE="${AUTOSTART_BASES[$((num - 1))]}"
    return 0
}

show_details() {
    header
    if ! choose_autostart; then
        pause
        return
    fi

    local base="$SELECTED_BASE"
    local userfile="$USER_AUTOSTART/$base"
    local systemfile="$SYSTEM_AUTOSTART/$base"
    local file source
    if [ -f "$userfile" ]; then
        file="$userfile"
        if [ -f "$systemfile" ]; then
            source="Benutzer-Override für Systemeintrag"
        else
            source="Benutzereintrag"
        fi
    else
        file="$systemfile"
        source="Systemeintrag"
    fi
    header
    echo "Name   : $(desktop_name "$file")"
    echo "Status : $(effective_state "$base")"
    echo "Quelle : $source"
    echo "Datei  : $file"
    echo "Exec   : $(desktop_exec "$file")"
    echo
    echo "--- Inhalt ---"
    cat "$file" 2>/dev/null || true
    pause
}

disable_autostart() {
    header
    if ! choose_autostart; then
        pause
        return
    fi

    local base="$SELECTED_BASE"
    local userfile="$USER_AUTOSTART/$base"
    local systemfile="$SYSTEM_AUTOSTART/$base"
    echo
    echo "Deaktiviere: $base"

    if [ -f "$userfile" ] && [ ! -f "$systemfile" ]; then
        # Eigener Benutzereintrag: Hidden=true setzen
        if grep -q '^Hidden=' "$userfile"; then
            sed -i 's/^Hidden=.*/Hidden=true/' "$userfile"
        else
            printf '\nHidden=true\n' >> "$userfile"
        fi
        if grep -q '^X-GNOME-Autostart-enabled=' "$userfile"; then
            sed -i 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=false/' "$userfile"
        else
            printf 'X-GNOME-Autostart-enabled=false\n' >> "$userfile"
        fi
        echo "OK: Benutzereintrag deaktiviert."
    else
        # Systemeintrag oder bestehender Override:
        # sauberen User-Override mit Hidden=true erstellen
        if [ -f "$systemfile" ]; then
            cp -a "$systemfile" "$userfile"
        fi

        if grep -q '^Hidden=' "$userfile"; then
            sed -i 's/^Hidden=.*/Hidden=true/' "$userfile"
        else
            printf '\nHidden=true\n' >> "$userfile"
        fi
        if grep -q '^X-GNOME-Autostart-enabled=' "$userfile"; then
            sed -i 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=false/' "$userfile"
        else
            printf 'X-GNOME-Autostart-enabled=false\n' >> "$userfile"
        fi

        echo "OK: Systemeintrag wurde nur für deinen Benutzer deaktiviert."
        echo "Die Systemdatei selbst wurde NICHT gelöscht."
    fi

    pause
}
enable_autostart() {
    header
    if ! choose_autostart; then
        pause
        return
    fi

    local base="$SELECTED_BASE"
    local userfile="$USER_AUTOSTART/$base"
    local systemfile="$SYSTEM_AUTOSTART/$base"

    echo
    echo "Aktiviere: $base"
    if [ -f "$userfile" ] && [ -f "$systemfile" ]; then
        # Wenn User-Datei ein Override für System ist, entfernen wir ihn.
        rm -f "$userfile"
        echo "OK: Benutzer-Override entfernt."
        echo "Der originale System-Autostart ist wieder aktiv."
    elif [ -f "$userfile" ]; then
        if grep -q '^Hidden=' "$userfile"; then
            sed -i 's/^Hidden=.*/Hidden=false/' "$userfile"
        else
            printf '\nHidden=false\n' >> "$userfile"
        fi
        if grep -q '^X-GNOME-Autostart-enabled=' "$userfile"; then
            sed -i 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=true/' "$userfile"
        else
            printf 'X-GNOME-Autostart-enabled=true\n' >> "$userfile"
        fi

        echo "OK: Benutzereintrag aktiviert."
    else
        echo "Der Systemeintrag ist bereits aktiv."
    fi

    pause
}

delete_user_autostart() {
    header
    if ! choose_autostart; then
        pause
        return
    fi
    local base="$SELECTED_BASE"
    local userfile="$USER_AUTOSTART/$base"
    local systemfile="$SYSTEM_AUTOSTART/$base"

    echo

    if [ ! -f "$userfile" ]; then
        echo "Dieser Eintrag gehört zum System und wird NICHT gelöscht."
        echo "Benutze stattdessen 'Deaktivieren'."
        pause
        return
    fi
    if [ -f "$systemfile" ]; then
        echo "Achtung: '$base' ist ein Benutzer-Override für einen Systemeintrag."
        echo "Wenn du ihn löschst, wird der originale Systemeintrag wieder aktiv."
    else
        echo "Achtung: Dieser Benutzereintrag wird vollständig gelöscht:"
        echo "$userfile"
    fi

    echo
    read -r -p "Wirklich löschen? [j/N]: " answer
    case "$answer" in
        j|J|ja|JA|Ja)
            rm -f "$userfile"
            echo "OK: Benutzerdatei gelöscht."
            ;;
        *)
            echo "Abgebrochen."
            ;;
    esac

    pause
}
show_user_services() {
    header
    echo "AKTIVIERTE SYSTEMD-BENUTZERDIENSTE"
    echo "------------------------------------------------------------"
    systemctl --user list-unit-files --type=service --state=enabled --no-pager 2>/dev/null || true
    echo
    echo "Hinweis:"
    echo "Diese Liste ist zusätzlich zu den GNOME/XDG-Autostarts."
    pause
}
disable_user_service() {
    header
    echo "Aktivierte systemd-Benutzerdienste:"
    echo
    mapfile -t services < <(
        systemctl --user list-unit-files --type=service --state=enabled --no-legend 2>/dev/null \
        | awk '{print $1}' \
        | sort
    )

    if [ "${#services[@]}" -eq 0 ]; then
        echo "Keine aktivierten Benutzer-Services gefunden."
        pause
        return
    fi
    local i=1
    for s in "${services[@]}"; do
        printf "%3d) %s\n" "$i" "$s"
        i=$((i + 1))
    done

    echo
    local num
    read -r -p "Nummer deaktivieren (0 = Abbrechen): " num

    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -eq 0 ]; then
        return
    fi

    if [ "$num" -lt 1 ] || [ "$num" -gt "${#services[@]}" ]; then
        echo "Ungültige Auswahl."
        pause
        return
    fi

    local service="${services[$((num - 1))]}"
    echo
    read -r -p "'$service' wirklich deaktivieren und stoppen? [j/N]: " answer
    case "$answer" in
        j|J|ja|JA|Ja)
            systemctl --user disable --now "$service"
            echo "OK."
            ;;
        *)
            echo "Abgebrochen."
            ;;
    esac

    pause
}


install_close_apps_helper() {
    cat > "$CLOSE_APPS_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -u

# STRG+Q soll alle Uwuntu-Diagnosefenster zuverlässig schließen.
# Mehrstufig:
#   1) Prozessbäume mit SIGTERM beenden
#   2) kurz warten und erneut suchen
#   3) verbleibende Prozesse notfalls mit SIGKILL entfernen
sleep 0.08

LOG="$HOME/uwuntu_close_apps.log"
SELF_PID="$$"

# Optionaler Prozess, der beim Schließen absichtlich am Leben bleiben muss.
# Der U-Updater setzt dies auf seine eigene PID, damit er nach dem Schließen
# der Diagnosefenster noch den neuen Kiosk starten kann.
KEEP_PID="${UWUNTU_KEEP_PID:-}"

keep_process() {
    local pid="$1"
    [ -n "$KEEP_PID" ] && [ "$pid" = "$KEEP_PID" ]
}

log_close() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S.%3N')" "$1" >> "$LOG" 2>/dev/null || true
}

descendants_postorder() {
    local parent="$1" child
    while read -r child; do
        [ -n "$child" ] || continue
        descendants_postorder "$child"
    done < <(pgrep -P "$parent" 2>/dev/null || true)
    printf '%s\n' "$parent"
}

signal_pattern() {
    local signal_name="$1"
    local pattern="$2"
    local root pid

    while read -r root; do
        [ -n "$root" ] || continue
        [ "$root" = "$SELF_PID" ] && continue
        keep_process "$root" && continue

        # Kinder zuerst, dann Elternprozess.
        while read -r pid; do
            [ -n "$pid" ] || continue
            [ "$pid" = "$SELF_PID" ] && continue
            keep_process "$pid" && continue
            kill "-$signal_name" "$pid" 2>/dev/null || true
        done < <(descendants_postorder "$root")
    done < <(pgrep -f -- "$pattern" 2>/dev/null || true)
}

close_pass() {
    local sig="$1"

    # Kiosk zuerst stoppen, damit während des Schließens nichts neu gestartet
    # oder erneut in den Vordergrund geholt werden kann.
    signal_pattern "$sig" '/.local/bin/start-kiosk-apps.sh'

    # GTK/Python-Hauptprogramme
    signal_pattern "$sig" '/tmp/network-check-'
    signal_pattern "$sig" '/tmp/wipe-auto-'
    signal_pattern "$sig" '/tmp/hardware-check\.'

    # Audio: Wrapper + echter Cache-Python-Prozess
    signal_pattern "$sig" '/.local/bin/uwuntu-audio-test.sh'
    signal_pattern "$sig" '/.cache/uwuntu-audio-test/'
    signal_pattern "$sig" 'uwuntu-audio-test-python'

    # Kamera: Wrapper + echter Cache-Python-Prozess
    signal_pattern "$sig" '/.local/bin/uwuntu-camera-test.sh'
    signal_pattern "$sig" '/.cache/uwuntu-camera-test/'
    signal_pattern "$sig" 'uwuntu-camera-test-python'

    # Touch / Display
    signal_pattern "$sig" '/.local/bin/uwuntu-touch-tester.sh'
    signal_pattern "$sig" '/.local/bin/uwuntu-display-test.sh'
    signal_pattern "$sig" 'uwuntu-touch-tester-python'
    signal_pattern "$sig" 'uwuntu-display-test-python'

    # Alte Snapshot-Instanz aus früheren Versionen
    pkill "-$sig" -x snapshot 2>/dev/null || true
}

if [ -n "$KEEP_PID" ]; then
    log_close "Shutdown gestartet · geschützte PID: $KEEP_PID"
else
    log_close "STRG+Q: Shutdown gestartet"
fi

close_pass TERM
sleep 0.22

# Zweiter TERM-Durchlauf fängt Prozesse ab, die während des ersten Durchlaufs
# gerade erst aus Wrappern entstanden sind.
close_pass TERM
sleep 0.28

# Harte letzte Absicherung: Nach insgesamt rund einer halben Sekunde darf kein
# Diagnosefenster mehr übrig bleiben.
close_pass KILL

if [ -n "$KEEP_PID" ]; then
    log_close "Shutdown abgeschlossen · geschützte PID blieb aktiv: $KEEP_PID"
else
    log_close "STRG+Q: Shutdown abgeschlossen"
fi
exit 0
EOF

    chmod +x "$CLOSE_APPS_SCRIPT"
}

install_force_update_helper() {
    # Der U-Updater braucht einen dauerhaft vorhandenen Manager. Der Ort,
    # von dem der Benutzer die heruntergeladene Installationsdatei gestartet
    # hat (Downloads, USB, /tmp, ...), darf deshalb keine Rolle spielen.
    # Wir halten immer eine feste, ausführbare Kopie unter ~/.local/bin vor.
    local manager_source manager_source_real manager_install_real
    manager_source="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
    manager_source_real="$(readlink -f "$manager_source" 2>/dev/null || printf '%s' "$manager_source")"
    manager_install_real="$(readlink -f "$MANAGER_INSTALL_PATH" 2>/dev/null || printf '%s' "$MANAGER_INSTALL_PATH")"

    if [ "$manager_source_real" != "$manager_install_real" ]; then
        local manager_tmp="${MANAGER_INSTALL_PATH}.new.$$"
        cp "$manager_source" "$manager_tmp" || {
            echo "FEHLER: Feste Manager-Kopie konnte nicht erstellt werden."
            return 1
        }
        chmod +x "$manager_tmp" || true
        mv -f "$manager_tmp" "$MANAGER_INSTALL_PATH" || {
            rm -f "$manager_tmp" 2>/dev/null || true
            echo "FEHLER: Feste Manager-Kopie konnte nicht installiert werden."
            return 1
        }
    else
        chmod +x "$MANAGER_INSTALL_PATH" 2>/dev/null || true
    fi

    # Kompatibilitätsdatei für bereits installierte Helper. Sie zeigt ab
    # jetzt immer auf den stabilen Installationsort und niemals auf Downloads.
    printf '%s\n' "$MANAGER_INSTALL_PATH" > "$MANAGER_PATH_FILE"

    local helper_tmp="${FORCE_UPDATE_SCRIPT}.new.$$"
    cat > "$helper_tmp" <<'EOF'
#!/usr/bin/env bash
set -u

RAW_URL="https://raw.githubusercontent.com/Davegage-byte/uwuntu/refs/heads/main/Ubuntu%20Autostart%20Manager.sh"
REF_API_URL="https://api.github.com/repos/Davegage-byte/uwuntu/git/ref/heads/main"
RAW_COMMIT_BASE="https://raw.githubusercontent.com/Davegage-byte/uwuntu"
RAW_MANAGER_PATH="Ubuntu%20Autostart%20Manager.sh"
PATH_FILE="$HOME/.config/uwuntu-manager-path"
DEFAULT_TARGET="$HOME/.local/bin/Ubuntu Autostart Manager.sh"
LOG="$HOME/uwuntu_force_update.log"
KIOSK="$HOME/.local/bin/start-kiosk-apps.sh"
CLOSE_APPS="$HOME/.local/bin/close-diagnostic-apps.sh"
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

status "Suche frisch auf GitHub nach Update …"

TMP="$(mktemp /tmp/uwuntu-manager-update.XXXXXX.sh)" || fail "Temporäre Datei konnte nicht erstellt werden." 14
REF_TMP="$(mktemp /tmp/uwuntu-manager-ref.XXXXXX.json)" || fail "Temporäre GitHub-Ref-Datei konnte nicht erstellt werden." 15
BACKUP="${TARGET}.update-backup"
trap 'rm -f "$TMP" "$REF_TMP" "${TARGET}.new" 2>/dev/null || true' EXIT

# Jeder Druck auf U muss GitHub wirklich neu abfragen.
# Zuerst wird der aktuelle Commit-SHA von main über die GitHub-API ermittelt.
# Anschließend laden wir die Manager-Datei an GENAU diesem Commit. Damit
# umgehen wir zusätzlich eine mögliche kurze Verzögerung bei der beweglichen
# main-RAW-Weitergabe. Wenn die API einmal nicht verfügbar/rate-limited ist,
# bleibt der bisherige main-RAW-Weg als Fallback erhalten.
CACHE_BUST="$(date +%s%N)-$$"
DOWNLOAD_URL="$RAW_URL"

if curl \
    --fail \
    --location \
    --silent \
    --show-error \
    --retry 1 \
    --retry-delay 1 \
    --connect-timeout 6 \
    --max-time 15 \
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
        printf '%s  GitHub main Commit: %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$latest_sha" >> "$LOG" 2>/dev/null || true
    else
        printf '%s  GitHub-Ref konnte nicht ausgewertet werden · RAW-main-Fallback\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG" 2>/dev/null || true
    fi
else
    printf '%s  GitHub-Ref-API nicht verfügbar · RAW-main-Fallback\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG" 2>/dev/null || true
fi

if ! curl \
    --fail \
    --location \
    --silent \
    --show-error \
    --retry 2 \
    --retry-delay 1 \
    --connect-timeout 8 \
    --max-time 45 \
    --header 'Cache-Control: no-cache, no-store, max-age=0' \
    --header 'Pragma: no-cache' \
    --output "$TMP" \
    "${DOWNLOAD_URL}?uwuntu_cache_bust=${CACHE_BUST}"
then
    fail "GitHub ist nicht erreichbar oder der Download ist fehlgeschlagen." 20
fi

[ -s "$TMP" ] || fail "GitHub hat eine leere Datei geliefert." 21
head -n 1 "$TMP" | grep -q '^#!/usr/bin/env bash' \
    || fail "Die heruntergeladene Datei ist kein gültiger Uwuntu-Manager." 22
grep -q '^main_menu()' "$TMP" \
    || fail "Die heruntergeladene Datei ist unvollständig." 23
bash -n "$TMP" >/dev/null 2>&1 \
    || fail "Die heruntergeladene Datei hat einen Syntaxfehler." 24

local_build="$(grep -m1 '^MANAGER_BUILD=[0-9][0-9]*$' "$TARGET" 2>/dev/null | cut -d= -f2 || true)"
remote_build="$(grep -m1 '^MANAGER_BUILD=[0-9][0-9]*$' "$TMP" 2>/dev/null | cut -d= -f2 || true)"

# Ab dieser Version besitzt der Manager eine monotone Buildnummer.
# Fehlt sie auf GitHub, ist dort definitiv noch die ältere Generation.
if [ -n "$local_build" ] && [ -z "$remote_build" ]; then
    status "GitHub-Version ist älter · kein Update"
    exit 0
fi

if [ -n "$local_build" ] && [ -n "$remote_build" ]; then
    if [ "$remote_build" -lt "$local_build" ]; then
        status "GitHub-Version ist älter · kein Update"
        exit 0
    fi
fi

if cmp -s "$TARGET" "$TMP"; then
    status "Bereits aktuell"
    exit 0
fi

status "Update gefunden · wird installiert …"

rm -f "$BACKUP" 2>/dev/null || true
cp -a "$TARGET" "$BACKUP" \
    || fail "Sicherung der bisherigen Version fehlgeschlagen." 30

chmod +x "$TMP" || true
cp "$TMP" "${TARGET}.new" \
    || fail "Neue Manager-Datei konnte nicht vorbereitet werden." 31
chmod +x "${TARGET}.new" || true
mv -f "${TARGET}.new" "$TARGET" \
    || fail "Ubuntu Autostart Manager konnte nicht ersetzt werden." 32

status "Installiere Uwuntu-Komponenten …"

if ! "$TARGET" --apply-update >> "$LOG" 2>&1; then
    cp -a "$BACKUP" "$TARGET" 2>/dev/null || true
    chmod +x "$TARGET" 2>/dev/null || true
    fail "Installation fehlgeschlagen · vorherige Manager-Version wiederhergestellt." 40
fi

rm -f "$BACKUP" 2>/dev/null || true
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
EOF

    chmod +x "$helper_tmp"
    # Atomar ersetzen: Falls gerade ein U-Update mit der bisherigen
    # Helper-Datei läuft, liest dessen Bash-Prozess seinen alten Inode
    # ungestört zu Ende.
    mv -f "$helper_tmp" "$FORCE_UPDATE_SCRIPT"
}


cleanup_legacy_kiosk_items() {
    echo "--- Alte Kiosk-Reste bereinigen ---"

    local removed=0
    for f in \
        "$USER_AUTOSTART/wipe-auto.desktop" \
        "$USER_AUTOSTART/wipe.desktop"
    do
        if [ -e "$f" ]; then
            rm -f "$f"
            echo "Entfernt: $f"
            removed=1
        fi
    done
    # Der von Ubuntu mitgelieferte Benutzer-ydotoold kollidiert mit
    # unserem eigenen Systemdienst /run/ydotool-kiosk.sock.
    # Unser ydotool-kiosk.service bleibt davon unberührt.
    if systemctl --user list-unit-files ydotool.service \
        --no-legend 2>/dev/null | grep -q 'ydotool.service'
    then
        systemctl --user disable --now ydotool.service \
            >/dev/null 2>&1 || true
        systemctl --user mask ydotool.service \
            >/dev/null 2>&1 || true
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        echo "Alter Benutzer-Service ydotool.service: deaktiviert + maskiert."
        removed=1
    fi
    if [ "$removed" -eq 0 ]; then
        echo "Keine alten Reste gefunden."
    fi
}

setup_ydotool() {
    echo "--- ydotool prüfen ---"

    if ! command -v ydotool >/dev/null 2>&1; then
        echo "ydotool fehlt. Installation wird versucht."

        if sudo -n true 2>/dev/null; then
            sudo -n apt-get install -y ydotool || return 1
        else
            sudo apt-get install -y ydotool || return 1
        fi
    fi

    echo "OK: $(command -v ydotool)"
    # Prüfen, ob ein nutzbarer Socket existiert.
    local socket=""
    for s in \
        "/run/ydotool-kiosk.sock" \
        "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/.ydotool_socket" \
        "/run/user/$(id -u)/.ydotool_socket" \
        "/tmp/.ydotool_socket"
    do
        if [ -S "$s" ] && [ -w "$s" ]; then
            socket="$s"
            break
        fi
    done

    if [ -n "$socket" ]; then
        echo "OK: ydotool-Socket vorhanden: $socket"
        return 0
    fi
    echo "Kein nutzbarer Socket gefunden."
    echo "Richte Kiosk-ydotoold ein ..."

    local sudo_cmd=(sudo)
    if sudo -n true 2>/dev/null; then
        sudo_cmd=(sudo -n)
    fi

    "${sudo_cmd[@]}" tee /etc/systemd/system/ydotool-kiosk.service >/dev/null <<'EOF'
[Unit]
Description=ydotool daemon for local kiosk automation
After=systemd-udevd.service

[Service]
Type=simple
ExecStart=/usr/bin/ydotoold --socket-path=/run/ydotool-kiosk.sock --socket-perm=0666
Restart=on-failure
RestartSec=1
[Install]
WantedBy=multi-user.target
EOF

    "${sudo_cmd[@]}" systemctl daemon-reload
    "${sudo_cmd[@]}" systemctl enable --now ydotool-kiosk.service
    sleep 1

    if [ ! -S /run/ydotool-kiosk.sock ]; then
        echo "FEHLER: /run/ydotool-kiosk.sock wurde nicht erstellt."
        return 1
    fi

    echo "OK: ydotool-Kiosk-Daemon läuft."
    return 0
}


setup_pyatspi() {
    echo "--- AT-SPI prüfen ---"
    if ! command -v python3 >/dev/null 2>&1; then
        echo "FEHLER: python3 wurde nicht gefunden."
        return 1
    fi

    if python3 -c 'import pyatspi' >/dev/null 2>&1; then
        echo "OK: python3-pyatspi ist verfügbar."
        return 0
    fi

    echo "python3-pyatspi fehlt. Installation wird versucht."

    if sudo -n true 2>/dev/null; then
        sudo -n apt-get install -y python3-pyatspi || return 1
    else
        sudo apt-get install -y python3-pyatspi || return 1
    fi
    if ! python3 -c 'import pyatspi' >/dev/null 2>&1; then
        echo "FEHLER: pyatspi lässt sich nach der Installation nicht importieren."
        return 1
    fi

    echo "OK: python3-pyatspi ist verfügbar."
    return 0
}


repair_dpkg_if_needed() {
    echo "Prüfe dpkg-Paketstatus ..."

    # dpkg --configure -a is safe to run even if there is nothing pending.
    # If an earlier apt/dpkg process was interrupted, this completes the
    # outstanding package configuration automatically.
    if sudo -n true >/dev/null 2>&1; then
        echo "dpkg-Reparatur: sudo -n"
        sudo -n dpkg --configure -a || return 1

    elif command -v pkexec >/dev/null 2>&1; then
        echo "dpkg-Reparatur: grafische Authentifizierung via pkexec"
        pkexec dpkg --configure -a || return 1

    else
        echo "dpkg-Reparatur: sudo-Fallback"
        sudo dpkg --configure -a || return 1
    fi

    echo "OK: dpkg-Paketstatus ist konsistent."
    return 0
}


install_all_dependencies() {
    echo "--- Uwuntu Basis-Abhängigkeiten prüfen ---"

    # A previously interrupted package operation otherwise makes every new
    # apt install fail with "dpkg was interrupted".
    repair_dpkg_if_needed || {
        echo "FEHLER: Der dpkg-Paketstatus konnte nicht repariert werden."
        return 1
    }

    local packages=(
        python3
        python3-gi
        gir1.2-gtk-3.0
        gir1.2-gtk-4.0
        gir1.2-gdkpixbuf-2.0
        gir1.2-gstreamer-1.0
        gstreamer1.0-plugins-base
        gstreamer1.0-plugins-good
        gstreamer1.0-gtk3
        python3-numpy
        python3-sounddevice
        python3-pil
        python3-opencv
        opencv-data
        libportaudio2
        pulseaudio-utils
        alsa-utils
        curl
        network-manager
        iproute2
        iputils-ping
        iw
        upower
        util-linux
        parted
        psmisc
        ydotool
        python3-pyatspi
        libinput-tools
        udev
        mokutil
        dmidecode
        procps
        xdg-utils
        wl-clipboard
        libglib2.0-bin
        desktop-file-utils
        brightnessctl
    )

    local missing=()
    local pkg
    for pkg in "${packages[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Fehlende Pakete: ${missing[*]}"
        echo "Installation wird automatisch gestartet ..."

        # U-Updates laufen aus dem Hardware-Check ohne Terminal. Ein normales
        # sudo kann dort kein Passwort abfragen. Deshalb:
        # 1) passwortloses sudo verwenden, wenn vorhanden
        # 2) sonst pkexec für die grafische Ubuntu-Authentifizierung
        # 3) klassisches sudo nur als letzter Fallback für Terminal-Starts
        if sudo -n true >/dev/null 2>&1; then
            echo "Paketinstallation: sudo -n"
            echo "APT-Cache wird vor der Installation bereinigt ..."
            sudo -n apt-get clean || return 1
            sudo -n apt-get update || return 1
            sudo -n env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y "${missing[@]}" || return 1

        elif command -v pkexec >/dev/null 2>&1; then
            echo "Paketinstallation: grafische Authentifizierung via pkexec"
            echo "APT-Cache wird vor der Installation bereinigt ..."
            pkexec apt-get clean || return 1
            pkexec env DEBIAN_FRONTEND=noninteractive \
                apt-get update || return 1
            pkexec env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y "${missing[@]}" || return 1

        else
            echo "Paketinstallation: sudo-Fallback"
            echo "APT-Cache wird vor der Installation bereinigt ..."
            sudo apt-get clean || return 1
            sudo apt-get update || return 1
            sudo env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y "${missing[@]}" || return 1
        fi
    else
        echo "OK: Alle Basis-Abhängigkeiten sind bereits installiert."
    fi

    # Nicht nur dpkg prüfen: die für Uwuntu kritischen Imports/Programme
    # müssen danach wirklich funktionieren.
    python3 - <<'PY_DEPS_CHECK' >/dev/null 2>&1 || return 1
import numpy
import sounddevice
import cv2
from PIL import Image
import pyatspi
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gst", "1.0")
from gi.repository import Gtk, Gst
PY_DEPS_CHECK

    python3 - <<'PY_GTK4_CHECK' >/dev/null 2>&1 || return 1
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gtk, GdkPixbuf
PY_GTK4_CHECK

    local cmd
    for cmd in curl nmcli ip ping iw upower lsblk wipefs partprobe ydotool libinput udevadm mokutil dmidecode pgrep pkill gsettings gapplication xdg-open wl-copy; do
        command -v "$cmd" >/dev/null 2>&1 || {
            echo "FEHLER: $cmd fehlt trotz Paketinstallation."
            return 1
        }
    done

    echo "OK: Uwuntu Basis-Abhängigkeiten vollständig."
    return 0
}


install_camera_test_app() {
    echo "--- Uwuntu Kamera-Test installieren / aktualisieren ---"

    cat > "$CAMERA_TEST_SCRIPT" <<'CAMERA_TEST_EOF'
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
CAMERA_TEST_EOF
    chmod +x "$CAMERA_TEST_SCRIPT"

    cat > "$CAMERA_TEST_APP_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Uwuntu Kamera Test
Comment=Cleaner Uwuntu Kamera-Test v1.20
Exec=$CAMERA_TEST_SCRIPT
Icon=camera-photo-symbolic
Terminal=false
StartupNotify=false
StartupWMClass=UwuntuCameraTest
Categories=Utility;System;
NoDisplay=false
EOF

    # Alten Uwuntu-Snapshot-Override entfernen, aber nur wenn er eindeutig von
    # unserem Kamera-Test stammt. Das originale Ubuntu-Snapshot-Paket bleibt.
    if [ -f "$CAMERA_TEST_LEGACY_DESKTOP" ] \
        && grep -q 'Name=Uwuntu Kamera Test' "$CAMERA_TEST_LEGACY_DESKTOP" 2>/dev/null
    then
        rm -f "$CAMERA_TEST_LEGACY_DESKTOP"
        echo "Alter Snapshot-Kamera-Override entfernt."
    fi

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
    fi

    echo "OK: Kamera-Test v1.20 installiert/aktualisiert."
    echo "App-ID:   com.david.UwuntuCameraTest"
    echo "Programm: $CAMERA_TEST_SCRIPT"
    echo "Desktop:  $CAMERA_TEST_APP_DESKTOP"
    return 0
}

install_touch_test_app() {
    echo "--- Uwuntu Touch-Tester installieren / aktualisieren ---"

    cat > "$TOUCH_TEST_SCRIPT" <<'TOUCH_TEST_EOF'
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


class TouchTarget(Gtk.EventBox):
    W = 160
    H = 115

    def __init__(self, owner, target_id):
        super().__init__()
        self.owner = owner
        self.target_id = target_id
        self.done = False
        self.touch_down = False

        self.set_size_request(self.W, self.H)
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
        outer.set_size_request(350, 105)
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
        sw, sh = allocation.width, allocation.height
        tw, th = TouchTarget.W, TouchTarget.H
        mx, my = 125, 85

        pos = {
            "top-left": (mx, my),
            "top-right": (max(mx, sw - mx - tw), my),
            "center": ((sw - tw)//2, (sh - th)//2),
            "bottom-left": (mx, max(my, sh - my - th)),
            "bottom-right": (max(mx, sw - mx - tw), max(my, sh - my - th)),
        }
        for key, (x, y) in pos.items():
            self.fixed.move(self.targets[key], x, y)

        pw, ph = 350, 105
        center_y = (sh - th)//2
        gap = 22
        self.fixed.move(self.panel, (sw - pw)//2, max(12, center_y - ph - gap))

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
TOUCH_TEST_EOF
    chmod +x "$TOUCH_TEST_SCRIPT"
    mkdir -p "$(dirname "$TOUCH_STATE_FILE")"

    echo "OK: Touch-Tester installiert/aktualisiert."
    echo "Programm: $TOUCH_TEST_SCRIPT"
    echo "Status:   $TOUCH_STATE_FILE"
    return 0
}


install_display_test_app() {
    echo "--- Uwuntu Display-Test installieren / aktualisieren ---"

    cat > "$DISPLAY_TEST_SCRIPT" <<'DISPLAY_TEST_EOF'
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
DISPLAY_TEST_EOF

    chmod +x "$DISPLAY_TEST_SCRIPT"
    mkdir -p "$(dirname "$DISPLAY_STATE_FILE")"
    echo "OK: Display-Test installiert/aktualisiert."
    echo "Programm: $DISPLAY_TEST_SCRIPT"
    echo "Status:   $DISPLAY_STATE_FILE"
    return 0
}

install_wipe_auto_app() {
    echo "--- Wipe Auto prüfen ---"

    install_close_apps_helper

    if ! command -v python3 >/dev/null 2>&1; then
        echo "FEHLER: python3 wurde nicht gefunden."
        return 1
    fi
    if ! python3 -c 'import gi; gi.require_version("Gtk","4.0"); from gi.repository import Gtk' >/dev/null 2>&1; then
        echo "GTK4/Python fehlt. Installation wird versucht."

        if sudo -n true 2>/dev/null; then
            sudo -n apt-get install -y python3-gi gir1.2-gtk-4.0 upower util-linux parted psmisc
        else
            sudo apt-get install -y python3-gi gir1.2-gtk-4.0 upower util-linux parted psmisc
        fi
    fi
    if ! python3 -c 'import gi; gi.require_version("Gtk","4.0"); from gi.repository import Gtk' >/dev/null 2>&1; then
        echo "FEHLER: GTK4/Python ist nicht verfügbar."
        return 1
    fi

    cat > "$WIPE_AUTO_SCRIPT" <<'WIPE_AUTO_EOF'
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
WIPE_AUTO_EOF

    chmod +x "$WIPE_AUTO_SCRIPT"
    cat > "$WIPE_AUTO_APP_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Wipe Auto
Comment=Battery Health und SSD Wipe
Exec=$WIPE_AUTO_SCRIPT
Icon=drive-harddisk-symbolic
Terminal=false
StartupNotify=true
StartupWMClass=com.david.WipeAuto
Categories=Utility;System;
NoDisplay=false
EOF

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
    fi
    echo "OK: Wipe Auto GTK-App installiert/aktualisiert."
    echo "App-ID: com.david.WipeAuto"
    echo "Programm: $WIPE_AUTO_SCRIPT"
    echo "Desktop:  $WIPE_AUTO_APP_DESKTOP"

    return 0
}



install_audio_test_app() {
    echo "--- Uwuntu Audio Test installieren / aktualisieren ---"

    cat > "$AUDIO_TEST_SCRIPT" <<'AUDIO_TEST_WRAPPER_EOF'
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
PY_FILE="$CACHE_DIR/audio_test_v1_20.py"
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


VERSION = "v1.20"

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

COL_RED = (242, 55, 55, 255)
COL_ORANGE = (255, 150, 18, 255)
COL_GREEN = (45, 220, 100, 255)


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
        try:
            self.stream = sd.InputStream(
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
        image = self.renderer.render(
            self.analyzer.waveform,
            self.analyzer.color_name
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

            return False

        # ----------------------------------------------------
        # Einzeltest fertig
        # ----------------------------------------------------
        if event == "pass":
            if side in ("left", "both", "right"):
                self.result_states[side] = "green"
                self.set_button_state(side, "green")

                # Nach einem AUTO-Fehler kann ein einzelner erfolgreicher
                # Nachtest den Gesamtstatus vervollständigen.
                if self.quick_play_enabled:
                    self.update_auto_from_individual_results()
            return False

        if event in ("fail", "weak", "error"):
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
            self.set_button_state("auto", "green")
            self.quick_play_enabled = True
            write_mic_state("tested" if self.analyzer.running else "missing")
            return False

        if event in ("auto_fail", "auto_weak"):
            self.set_button_state("auto", "red")
            write_mic_state("detected" if self.analyzer.running else "missing")

            # Bereits grüne Ergebnisse bleiben gültig. Rote Einzelkanäle
            # können jetzt einzeln erneut abgespielt UND gemessen werden.
            self.quick_play_enabled = True
            return False

        if event == "idle":
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
AUDIO_TEST_WRAPPER_EOF

    chmod +x "$AUDIO_TEST_SCRIPT"

    # Der bisherige Wipe-Auto-Slot des Tiling Assistant wird absichtlich
    # weiterverwendet. Dadurch muss das vorhandene 4-Tile-Layout nicht
    # neu angelernt werden: Slot 3 startet jetzt den Audio Test.
    cat > "$AUDIO_TEST_APP_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Uwuntu Audio Test
Comment=Mikrofon-Wellenform und automatischer Lautsprecher-Test
Exec=$AUDIO_TEST_SCRIPT
Icon=audio-speakers-symbolic
Terminal=false
StartupNotify=true
StartupWMClass=com.david.UwuntuAudioTest
Categories=Utility;System;
NoDisplay=false
EOF

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
    fi

    echo "OK: Uwuntu Audio Test v1.20 installiert/aktualisiert."
    echo "Programm: $AUDIO_TEST_SCRIPT"
    echo "Desktop-Slot: $AUDIO_TEST_APP_DESKTOP"
    return 0
}

install_hardware_check_app() {
    echo
    echo "--- Hardware Check installieren / aktualisieren ---"

    install_close_apps_helper
    install_force_update_helper

    local hw_missing=()
    for pkg in python3-gi gir1.2-gtk-4.0 python3-pyatspi libinput-tools udev mokutil dmidecode wl-clipboard; do
        dpkg -s "$pkg" >/dev/null 2>&1 || hw_missing+=("$pkg")
    done
    if [ "${#hw_missing[@]}" -gt 0 ]; then
        echo "Hardware-Check-Abhängigkeiten fehlen: ${hw_missing[*]}"
        if sudo -n true >/dev/null 2>&1; then
            sudo -n apt-get update || return 1
            sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y "${hw_missing[@]}" || return 1
        else
            sudo apt-get update || return 1
            sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${hw_missing[@]}" || return 1
        fi
    fi

    cat > "$HARDWARE_CHECK_SCRIPT" <<'HARDWARE_CHECK_EOF'
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
import pyatspi
from pathlib import Path
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

        # Cache für die AT-SPI-Erkennung des GNOME-Power-Dialogs.
        # Die eigentliche Prüfung läuft vollständig asynchron im Hintergrund.
        # Audio-Pfeiltasten dürfen dadurch niemals auf AT-SPI warten.
        self.power_dialog_cache_at = 0.0
        self.power_dialog_cache_value = False
        self.power_dialog_probe_running = False
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
        self.window.set_title("Hardware Check v4.5.72")
        self.window.set_default_size(860, 360)

        # Einheitliche Titelleiste wie Network/Wipe und Audio.
        self.header_bar = Gtk.HeaderBar()
        self.header_bar.set_show_title_buttons(True)

        title_label = Gtk.Label(label="Hardware Check v4.5.72")
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
        # GNOME-Powerdialog im Hintergrund beobachten. Dieser Timer blockiert
        # niemals die Pfeiltasten; der eigentliche AT-SPI-Scan läuft im Thread.
        GLib.timeout_add(250, self.poll_power_dialog_status)
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
                "IPU7 KAMERA – LINUX NICHT TESTBAR",
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
            self.set_touch_status_ui("orange", "NICHT SICHER / ABGEBROCHEN")
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

    def _power_dialog_probe_worker(self):
        """AT-SPI-Powerdialog-Prüfung isoliert und ohne UI-Blockierung."""
        probe_code = r"""
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


def main():
    try:
        desktop = pyatspi.Registry.getDesktop(0)
        app_count = desktop.childCount
    except Exception:
        print("0")
        return

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
                print("1")
                return

    print("0")


main()
"""
        detected = False
        try:
            result = subprocess.run(
                [sys.executable, "-c", probe_code],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=0.40,
                check=False,
            )
            detected = result.returncode == 0 and result.stdout.strip() == "1"
        except subprocess.TimeoutExpired:
            log("Power-Dialog-Probe: Timeout im Hintergrund")
        except Exception as exc:
            log(f"Power-Dialog-Probe Fehler: {exc}")

        def finish_probe():
            self.power_dialog_cache_value = detected
            self.power_dialog_cache_at = time.monotonic()
            self.power_dialog_probe_running = False
            return False

        GLib.idle_add(finish_probe)

    def poll_power_dialog_status(self):
        """Powerdialog-Cache aktualisieren, ohne GTK oder Hotkeys zu blockieren."""
        if self.power_dialog_probe_running:
            return True

        self.power_dialog_probe_running = True
        threading.Thread(
            target=self._power_dialog_probe_worker,
            name="uwuntu-power-dialog-probe",
            daemon=True,
        ).start()
        return True

    def system_power_dialog_open(self):
        """Nur den bereits ermittelten Cache lesen – ohne jede Wartezeit."""
        # Falls der periodische Timer noch nicht gelaufen ist, Prüfung nebenbei
        # anstoßen. Der aktuelle Pfeiltastendruck wird dadurch NICHT verzögert.
        self.poll_power_dialog_status()
        return bool(self.power_dialog_cache_value)

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
            if visible == "keyboard":
                try:
                    _, key_state, raw_code = action.split(":", 2)
                    code = int(raw_code)
                except (TypeError, ValueError):
                    return False

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
            # Solange der GNOME-Power-/Ausschalt-Dialog offen ist, gehören die
            # Pfeiltasten ausschließlich diesem Systemdialog. Die Erkennung
            # stammt aus einem asynchron gepflegten Cache und verzögert den
            # Audiotastendruck selbst nicht mehr.
            if self.system_power_dialog_open():
                log(
                    "Audio-Hotkey blockiert: "
                    "GNOME Power-/Ausschalt-Dialog ist geöffnet"
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

    def block_desktop_shortcuts_for_keyboard_test(self):
        """GNOME-Desktop-Shortcuts temporär deaktivieren, ohne Input-Grab.

        Nur GSettings-Werte im Array-Format werden verändert. Das deckt u. a.
        Print Screen/Screenshot, Alt+F4, Super-Kombinationen, Workspace- und
        Tiling-Keybindings ab. Bereits leere Bindings bleiben unberührt.
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

        log(
            f"Keyboard-Test: {len(saved)} Desktop-Keybinding(s) "
            "temporär deaktiviert · Input bleibt read-only"
        )
        return False

    def restore_keyboard_shortcuts_async(self):
        """Desktop-Keybindings nach sichtbarem Wechsel im Hintergrund restaurieren."""
        def worker():
            try:
                self.restore_super_after_keyboard_test()
                self.restore_desktop_shortcuts_after_keyboard_test()
            except Exception as exc:
                log(f"Keyboard-Test: asynchrones Shortcut-Restore fehlgeschlagen: {exc}")

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
        self.restore_super_after_keyboard_test()
        self.restore_desktop_shortcuts_after_keyboard_test()
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
HARDWARE_CHECK_EOF

    chmod +x "$HARDWARE_CHECK_SCRIPT"
    cat > "$HARDWARE_CHECK_APP_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Hardware Check
Comment=TPM Secure Boot HDMI Eingabegeräte USB Display und Benchmark testen
Exec=$HARDWARE_CHECK_SCRIPT
Icon=utilities-system-monitor-symbolic
Terminal=false
StartupNotify=false
X-GNOME-UsesNotifications=false
StartupWMClass=com.david.HardwareCheck
Categories=Utility;System;
NoDisplay=false
EOF

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
    fi
    echo "OK: Hardware Check installiert/aktualisiert."
    echo "App-ID: com.david.HardwareCheck"
    echo "Programm: $HARDWARE_CHECK_SCRIPT"
    echo "Desktop:  $HARDWARE_CHECK_APP_DESKTOP"

    return 0
}


install_kiosk() {
    header
    echo "4-Felder Diagnose-Kiosk einrichten"
    echo "------------------------------------------------------------"
    echo
    echo "Layout:"
    echo "  oben links   = Network Check + Wipe Auto"
    echo "  oben rechts  = Uwuntu Kamera Test"
    echo "  unten links  = Uwuntu Audio Test"
    echo "  unten rechts = Hardware Check"
    echo

    if ! install_all_dependencies; then
        echo "FEHLER: Uwuntu Basis-Abhängigkeiten konnten nicht vollständig installiert werden."
        pause
        return 1
    fi

    # Menüpunkt 1 ist ab jetzt wirklich "ALLES": Network/Wipe wird zuerst
    # installiert/aktualisiert, danach Kamera, Touch, Display, Audio, Hardware
    # Check, Helper und Kiosk. Kein vorheriger manueller Modulschritt nötig.
    if ! install_network_check; then
        echo "FEHLER: Network Check + Wipe Auto konnten nicht installiert werden."
        pause
        return 1
    fi

    if ! install_camera_test_app; then
        pause
        return 1
    fi
    if ! install_touch_test_app; then
        pause
        return 1
    fi
    if ! install_display_test_app; then
        pause
        return 1
    fi
    if ! install_wipe_auto_app; then
        pause
        return 1
    fi
    # Slot 3 des bisherigen Tiling-Layouts wird vom Audio Test belegt.
    # Der historische Desktop-Dateiname com.david.WipeAuto.desktop bleibt
    # dafür erhalten. Der separate Wipe-Launcher hat einen eigenen Dateinamen
    # und kann diesen Slot deshalb nicht mehr versehentlich überschreiben.
    if ! install_audio_test_app; then
        pause
        return 1
    fi
    if ! install_hardware_check_app; then
        pause
        return 1
    fi

    cleanup_legacy_kiosk_items

    if ! setup_ydotool; then
        echo
        echo "FEHLER bei der ydotool-Einrichtung."
        pause
        return 1
    fi

    if ! setup_pyatspi; then
        echo
        echo "FEHLER bei der AT-SPI-Einrichtung."
        pause
        return 1
    fi
    # Network Check darf im 4-Felder-Modus NICHT zusätzlich separat
    # per GNOME-Autostart starten. Er wird vom Tiling Assistant
    # zusammen mit Kamera-Test und Wipe Auto gestartet.
    if [ -f "$NETWORK_CHECK_AUTOSTART" ]; then
        write_network_check_autostart false
        echo
        echo "Hinweis: Separater Network-Check-Autostart wurde deaktiviert,"
        echo "damit Network Check nicht doppelt startet."
    fi

    cat > "$KIOSK_LAUNCHER" <<'EOF'
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
# ------------------------------------------------------------
# Begrüßungs-/Bereitschaftssound
# ------------------------------------------------------------
# Der Sound kommt ganz am Ende. Damit ist er gleichzeitig das Signal:
# Wipe Auto ist bereit und LÖSCHEN sollte den Tastaturfokus haben.
LOGIN_SOUND="/usr/share/sounds/Yaru/stereo/desktop-login.oga"
if [ "$FOCUS_OK" -eq 1 ]; then
    if command -v paplay >/dev/null 2>&1 && [ -f "$LOGIN_SOUND" ]; then
        echo "Spiele Bereitschaftssound ..."
        paplay "$LOGIN_SOUND" >/dev/null 2>&1 &
    else
        echo "Hinweis: Bereitschaftssound nicht verfügbar."
    fi
else
    echo "Kein Bereitschaftssound: LÖSCHEN hat keinen bestätigten Fokus."
fi

echo "Kiosk fertig: $(date)"
EOF

    chmod +x "$KIOSK_LAUNCHER"
    # Alten Firefox/Snapshot-Autostart entfernen, damit nicht zwei
    # Kiosk-Einträge gleichzeitig feuern.
    rm -f "$OLD_KIOSK_DESKTOP"

    cat > "$KIOSK_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Diagnostic 4-Tile Kiosk
Comment=Startet das Diagnose-Layout über Tiling Assistant
Exec=$KIOSK_LAUNCHER
Terminal=false
X-GNOME-Autostart-enabled=true
Hidden=false
NoDisplay=false
EOF
    echo
    echo "OK: 4-Felder-Kiosk eingerichtet."
    echo
    echo "Autostart:"
    echo "  $KIOSK_DESKTOP"
    echo
    echo "Tiling-Assistant Layout:"
    echo "  1) 0--0--0.5--0.5       -> Network Check + Wipe Auto"
    echo "  2) 0.5--0--0.5--0.5     -> Uwuntu Kamera Test"
    echo "  3) 0--0.5--0.5--0.5     -> Uwuntu Audio Test"
    echo "  4) 0.5--0.5--0.5--0.5   -> Hardware Check"
    echo
    echo "WICHTIG:"
    echo "Das bestehende Layout kann weiterverwendet werden: Slot 1 bleibt NetworkCheck, Slot 3 nutzt den bisherigen WipeAuto-Desktop-Slot für Audio."
    echo "Der Shortcut bleibt Strg+D."
    echo
    echo "Firefox wird vom Kiosk nicht mehr gestartet."
    echo
    echo "Startfokus:"
    echo "  Wipe Auto wird nach dem Start aktiviert und LÖSCHEN"
    echo "  bekommt über AT-SPI gezielt den Tastaturfokus."
    echo "  Es gibt keine zusätzliche 90s-App-Wartezeit mehr."
    echo "  Kamera-Test und Hardware Check müssen zuerst stabil erschienen sein."
    echo "  Danach wird das gemeinsame Network/Wipe-Fenster direkt aktiviert."
    echo "  AT-SPI fokussiert dort gezielt LÖSCHEN; keine Maus/Alt+Tab nötig."
    echo "  Ein fokussierter WIPE-SSD-Button wird deutlich BLAU."
    echo "  Sobald der Fokus einmal bestätigt ist, beendet sich die"
    echo "  Fokus-Automatik sofort - Enter/JA kann direkt bedient werden."
    echo "  Der Bereitschaftssound kommt direkt nach bestätigtem Fokus."
    echo "  ENTER 1 = LÖSCHEN"
    echo "  ENTER 2 = JA / Löschen bestätigen"
    echo
    echo "Bereitschaftssound:"
    echo "  /usr/share/sounds/Yaru/stereo/desktop-login.oga"
    echo "  Er ertönt erst, wenn der Kiosk vollständig bereit ist."
    pause
    return 0
}

test_kiosk() {
    header

    if [ ! -x "$KIOSK_LAUNCHER" ]; then
        echo "4-Felder-Kiosk ist noch nicht installiert."
        echo "Bitte zuerst Menüpunkt 1 verwenden."
        pause
        return
    fi
    echo "4-Felder-Kiosk wird jetzt manuell gestartet."
    echo
    echo "Für einen sauberen Test vorher schließen:"
    echo "  - Network Check"
    echo "  - Uwuntu Kamera Test"
    echo "  - Touch-Tester (falls geöffnet)"
    echo "  - Hardware Check"
    echo "  - offene Wipe-Auto/Zenity-Fenster"
    echo
    echo "Danach sollte Strg+D genau einmal ausgelöst werden."
    echo

    "$KIOSK_LAUNCHER" &
    echo "Gestartet."
    echo
    echo "Log:"
    echo "$HOME/kiosk_start.log"

    pause
}
show_kiosk_log() {
    header
    echo "KIOSK-LOG"
    echo "------------------------------------------------------------"
    if [ -f "$HOME/kiosk_start.log" ]; then
        tail -n 200 "$HOME/kiosk_start.log"
    else
        echo "Noch kein Log vorhanden."
    fi
    pause
}


network_check_status() {
    if [ ! -x "$NETWORK_CHECK_SCRIPT" ]; then
        echo "NICHT INSTALLIERT"
        return
    fi
    if [ ! -f "$NETWORK_CHECK_AUTOSTART" ]; then
        echo "INSTALLIERT / AUTOSTART AUS"
        return
    fi

    if grep -qiE '^Hidden=true$' "$NETWORK_CHECK_AUTOSTART" 2>/dev/null \
        || grep -qiE '^X-GNOME-Autostart-enabled=false$' "$NETWORK_CHECK_AUTOSTART" 2>/dev/null
    then
        echo "AUTOSTART AUS"
    else
        echo "AUTOSTART EIN"
    fi
}
write_network_check_desktop() {
    cat > "$NETWORK_CHECK_APP_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Network Check + Wipe Auto
Comment=Network Check v2.28 und Wipe Auto v3.32
Exec=$NETWORK_CHECK_SCRIPT
Icon=network-transmit-receive-symbolic
Terminal=false
StartupNotify=true
StartupWMClass=com.david.NetworkCheck
Categories=Utility;System;
NoDisplay=false
EOF
}

write_network_check_autostart() {
    local enabled="${1:-true}"

    cp "$NETWORK_CHECK_APP_DESKTOP" "$NETWORK_CHECK_AUTOSTART"
    if [ "$enabled" = "true" ]; then
        printf '\nX-GNOME-Autostart-enabled=true\nHidden=false\n' >> "$NETWORK_CHECK_AUTOSTART"
    else
        printf '\nX-GNOME-Autostart-enabled=false\nHidden=true\n' >> "$NETWORK_CHECK_AUTOSTART"
    fi
}

install_network_check() {
    install_close_apps_helper
    header
    echo "Network Check installieren / aktualisieren"
    echo "------------------------------------------------------------"
    echo
    echo "Installiere Network Check v2.28 + Wipe Auto v3.32 im gemeinsamen Fenster."
    echo "Network Check und Wipe Auto teilen sich künftig das obere linke Fenster."
    echo

    cat > "$NETWORK_CHECK_SCRIPT" <<'NETWORK_CHECK_SCRIPT_EOF'
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
# Network Check - separater Test
# ============================================================
# - Verändert den bestehenden Kiosk / Autostart NICHT
# - Eigenes GTK4-Fenster
# - LAN und WLAN getrennt
# - Live Download / Upload
# - Automatischer Test beim Start NUR für die aktive Verbindung
# - Automatischer Test bei Verbindungswechsel
# - REFRESH = nur die aktuell aktive LAN/WLAN-Verbindung neu testen
# - EXIT = Programm beenden
#
# Ablauf:
#   LINK -> kurzer PING -> DOWNLOAD -> UPLOAD
# Speedtest:
#   Download: Datalix Looking Glass Frankfurt
#   Upload:   Cloudflare /__up
# ============================================================
need_install=0

if ! python3 -c 'import gi; gi.require_version("Gtk","4.0"); from gi.repository import Gtk' >/dev/null 2>&1; then
    need_install=1
fi

for cmd in curl nmcli ip ping iw upower lsblk wipefs partprobe; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        need_install=1
    fi
done

if [ "$need_install" -eq 1 ]; then
    echo "Einige kleine Abhängigkeiten fehlen."
    echo "Installiere GTK-Python, Netzwerk- und Wipe-Abhängigkeiten ..."
    if sudo -n true 2>/dev/null; then
        sudo -n apt-get update || exit 1
        sudo -n apt-get install -y \
            python3-gi gir1.2-gtk-4.0 curl network-manager iproute2 iputils-ping iw upower util-linux parted psmisc
    else
        sudo apt-get update || exit 1
        sudo apt-get install -y \
            python3-gi gir1.2-gtk-4.0 curl network-manager iproute2 iputils-ping iw upower util-linux parted psmisc
    fi
fi

if ! python3 -c 'import gi; gi.require_version("Gtk","4.0"); from gi.repository import Gtk' >/dev/null 2>&1; then
    echo "FEHLER: GTK4/Python ist nicht verfügbar."
    exit 10
fi
for cmd in curl nmcli ip ping; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "FEHLER: $cmd fehlt."
        exit 11
    fi
done

TMP_PY="$(mktemp /tmp/network-check-XXXXXX.py)"
trap 'rm -f "$TMP_PY"' EXIT

cat > "$TMP_PY" <<'PY'
#!/usr/bin/env python3

import gi
gi.require_version("Gtk", "4.0")

from gi.repository import Gtk, GLib, Gdk, Pango

import os
import re
import signal
import subprocess
import threading
import time
import queue
from datetime import datetime
from pathlib import Path
VERSION = "2.28"
# ============================================================
# EINSTELLUNGEN
# Diese Grenzwerte sind für den ersten Praxistest bewusst
# einfach gehalten und können später angepasst werden.
# ============================================================

# Harte LAN-Regel:
LAN_LINK_MIN = 1000.0       # Mbps

# WLAN-Link: vorläufiger Mindestwert
WIFI_LINK_MIN = 100.0       # Mbps
# Internet-Durchsatz: vorläufige PASS-Grenzen
LAN_DOWNLOAD_MIN = 800.0    # Mbps
LAN_UPLOAD_MIN = 800.0      # Mbps
WIFI_DOWNLOAD_MIN = 50.0    # Mbps
WIFI_UPLOAD_MIN = 100.0     # Mbps

# Einheitliche Farbabstufung:
# Grün = Zielwert erreicht
# Orange = noch brauchbar, mindestens 70 % des Zielwerts
# Rot = darunter
NETWORK_WARN_FACTOR = 0.70

# Ping-Farben
PING_GOOD_MAX_MS = 40.0
PING_WARN_MAX_MS = 100.0

# Je Richtung maximal ungefähr 2,5 Sekunden.
# Gesamttest pro Verbindung damit ungefähr 5 Sekunden.
PHASE_SECONDS = 5.0
SAMPLE_SECONDS = 0.25
# Mehrere parallele Transfers sättigen schnelle Gigabit-Leitungen.
#
# Download:
# 4 parallele Streams gegen eine 10-GB-Testdatei in Frankfurt.
# Kein Stream kann innerhalb unserer 5 Sekunden fertig werden.
DOWNLOAD_STREAMS = 4
#
# Upload:
# 4 Streams reichen; jeder Stream bekommt 250 MB Daten angeboten.
# Bei insgesamt 1 Gbit/s wird auch davon keiner innerhalb von 5 Sekunden fertig.
UPLOAD_STREAMS = 4
# Die ersten Millisekunden enthalten Verbindungsaufbau / Hochlauf.
# Sie werden live angezeigt, aber nicht in den End-Durchschnitt genommen.
WARMUP_SECONDS = 0.5

# Endwert: Durchschnitt der schnellsten 50 % der stabilisierten Samples.
# Dadurch zieht der TCP-Hochlauf den Endwert nicht künstlich herunter,
# einzelne kurze Peaks bestimmen das Ergebnis aber ebenfalls nicht allein.
TOP_SAMPLE_FRACTION = 0.50

# Kleine Cloudflare-Anfrage als Internet-Bereitschaftstest.
CONNECTIVITY_TIMEOUT = 15.0
# Der öffentliche Cloudflare-Endpunkt reagiert bei sehr großen
# Einzelrequests nicht auf allen Systemen zuverlässig.
# 99.999.999 Bytes pro Stream ist groß genug für unseren kurzen Test.
# Download:
# Datalix Looking Glass in Frankfurt stellt große Speedtest-Dateien bereit.
# 10 GB pro Stream sind absichtlich viel größer als nötig:
# Wir brechen nach 5 Sekunden ab, sodass kein Stream neu gestartet werden muss.
DOWNLOAD_URL = "https://lg.datalix.de/download.php?size=10gb"
# Upload bleibt bei Cloudflare, weil dieser Test bei uns stabil funktioniert.
CF_UP_BYTES = 250000000

CF_CHECK = "https://speed.cloudflare.com/__down?bytes=1000"
CF_UP = "https://speed.cloudflare.com/__up"

# Sehr kurzer ICMP-Test vor dem Speedtest. Der zweite Host wird nur probiert,
# wenn der erste nicht innerhalb von 1 Sekunde antwortet.
PING_TARGETS = ("1.1.1.1", "8.8.8.8")
PING_TIMEOUT_SECONDS = 1

LOG = Path.home() / "network_check.log"

ENV_C = os.environ.copy()
ENV_C["LC_ALL"] = "C"
ENV_C["LANG"] = "C"
# ============================================================
# Hilfsfunktionen
# ============================================================

def log(message):
    line = f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]}  {message}"
    try:
        with LOG.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass
    print(line, flush=True)

def run_text(args, timeout=4):
    try:
        p = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            env=ENV_C,
        )
        return p.stdout.strip()
    except Exception:
        return ""


def format_mbps(value, decimals=0):
    if value is None:
        return "--"
    if decimals:
        return f"{value:.1f} Mbps"
    return f"{value:,.0f}".replace(",", ".") + " Mbps"

def get_devices():
    """
    Liefert pro Typ (ethernet/wifi) alle von NetworkManager
    bekannten Geräte. Verbundene Geräte werden zuerst sortiert.
    """
    out = run_text(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE", "device", "status"])
    result = {"ethernet": [], "wifi": []}
    for raw in out.splitlines():
        # nmcli escaped Doppelpunkte sind bei normalen Interface-Namen
        # nicht relevant; maxsplit hält den Parser trotzdem klein.
        parts = raw.split(":", 2)
        if len(parts) != 3:
            continue

        dev, typ, state = parts
        if typ not in result:
            continue
        if not dev or dev == "lo":
            continue
        result[typ].append({
            "iface": dev,
            "type": typ,
            "state": state,
            "connected": state == "connected",
        })

    for typ in result:
        result[typ].sort(key=lambda d: (not d["connected"], d["iface"]))

    return result


def get_default_iface():
    out = run_text(["ip", "-4", "route", "show", "default"])
    candidates = []

    for line in out.splitlines():
        parts = line.split()
        if "dev" not in parts:
            continue
        try:
            iface = parts[parts.index("dev") + 1]
        except Exception:
            continue

        metric = 0
        if "metric" in parts:
            try:
                metric = int(parts[parts.index("metric") + 1])
            except Exception:
                metric = 999999

        candidates.append((metric, iface))

    if not candidates:
        return None

    candidates.sort()
    return candidates[0][1]

def ethernet_link_speed(iface):
    p = Path("/sys/class/net") / iface / "speed"
    try:
        raw = p.read_text().strip()
        speed = float(raw)
        if speed > 0:
            return speed
    except Exception:
        pass
    return None


def wifi_link_speed(iface):
    if not shutil_which("iw"):
        return None

    out = run_text(["iw", "dev", iface, "link"])
    # Bevorzugt RX, falls vorhanden, sonst TX.
    rx = re.search(r"rx bitrate:\s*([0-9.]+)\s*MBit/s", out, re.I)
    tx = re.search(r"tx bitrate:\s*([0-9.]+)\s*MBit/s", out, re.I)

    match = rx or tx
    if not match:
        return None

    try:
        return float(match.group(1))
    except Exception:
        return None

def shutil_which(cmd):
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        p = Path(directory) / cmd
        if p.exists() and os.access(p, os.X_OK):
            return str(p)
    return None


def link_speed(iface, kind):
    if kind == "lan":
        return ethernet_link_speed(iface)
    return wifi_link_speed(iface)

def iface_counter(iface, direction):
    stat = "rx_bytes" if direction == "download" else "tx_bytes"
    p = Path("/sys/class/net") / iface / "statistics" / stat
    try:
        return int(p.read_text().strip())
    except Exception:
        return 0

def iface_mac(iface):
    """Aktuelle MAC-Adresse des Interfaces aus sysfs lesen."""
    p = Path("/sys/class/net") / iface / "address"
    try:
        mac = p.read_text().strip().upper()
        if re.fullmatch(r"[0-9A-F]{2}(?::[0-9A-F]{2}){5}", mac):
            return mac
    except Exception:
        pass
    return None
# ============================================================
# GTK-Karte
# ============================================================

class ConnectionCard:
    def __init__(self, title):
        self.title = title
        self.base_title = title

        self.root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.root.add_css_class("card")

        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)

        # LAN/WLAN + MAC und Interface liegen jetzt in derselben Zeile.
        # Das Interface behält bewusst die kleine graue Darstellung.
        identity = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=7)
        identity.set_hexpand(True)

        self.title_label = Gtk.Label(label=title)
        self.title_label.set_xalign(0)
        self.title_label.add_css_class("card-title")
        self.title_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.title_label.set_max_width_chars(48)

        self.interface_label = Gtk.Label(label="Interface: --")
        self.interface_label.set_xalign(0)
        self.interface_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.interface_label.set_max_width_chars(32)
        self.interface_label.add_css_class("interface")

        identity.append(self.title_label)
        identity.append(self.interface_label)

        self.state_label = Gtk.Label(label="CHECKING")
        # Nach dem kompakten Horizontal-Layout ist genug Platz vorhanden:
        # Statusmeldungen wieder vollständig ausschreiben, ohne Ellipse.
        self.state_label.set_ellipsize(Pango.EllipsizeMode.NONE)
        self.state_label.set_max_width_chars(24)
        self.state_label.add_css_class("badge")
        self.set_widget_class(self.state_label, "warn")

        header.append(identity)
        header.append(self.state_label)
        self.root.append(header)

        metrics = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        metrics.set_homogeneous(True)

        self.link_value = self.metric(metrics, "LINK")
        self.ping_value = self.metric(metrics, "PING")
        self.down_value = self.metric(metrics, "DOWNLOAD")
        self.up_value = self.metric(metrics, "UPLOAD")

        # Noch nicht geprüft = überall Orange.
        for widget in (
            self.link_value,
            self.ping_value,
            self.down_value,
            self.up_value,
        ):
            self.set_widget_class(widget, "warn")

        self.root.append(metrics)

        self.note_label = Gtk.Label(label="")
        self.note_label.set_xalign(0)
        self.note_label.set_wrap(False)
        self.note_label.set_ellipsize(Pango.EllipsizeMode.END)
        self.note_label.set_max_width_chars(80)
        self.note_label.add_css_class("note")
        self.root.append(self.note_label)

    def metric(self, parent, caption):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
        box.add_css_class("metric")

        cap = Gtk.Label(label=caption)
        cap.add_css_class("metric-caption")
        value = Gtk.Label(label="--")
        value.add_css_class("metric-value")
        value.add_css_class("neutral")

        box.append(cap)
        box.append(value)
        parent.append(box)
        return value

    def set_widget_class(self, widget, klass):
        for c in ("good", "bad", "warn", "neutral", "live"):
            widget.remove_css_class(c)
        widget.add_css_class(klass)
    def set_title_mac(self, mac=None, adapter_present=True):
        # Fehlende Hardware bzw. nicht lesbare MAC = orange/unklar.
        # Eine echte Null-MAC bleibt rot, weil das ein klarer Fehler ist.
        self.title_label.remove_css_class("mac-error")
        self.title_label.remove_css_class("mac-warning")

        if not adapter_present:
            self.title_label.set_text(f"{self.base_title} - KEINE NETZWERKKARTE")
            self.title_label.add_css_class("mac-warning")
            return

        if not mac:
            self.title_label.set_text(f"{self.base_title} - KEINE MAC")
            self.title_label.add_css_class("mac-warning")
            return

        self.title_label.set_text(f"{self.base_title} - {mac}")

        if mac == "00:00:00:00:00:00":
            self.title_label.add_css_class("mac-error")

    def set_state(self, text, klass):
        self.state_label.set_text(text)
        self.set_widget_class(self.state_label, klass)
    def set_metric(self, which, text, klass="neutral"):
        widget = {
            "link": self.link_value,
            "ping": self.ping_value,
            "down": self.down_value,
            "up": self.up_value,
        }[which]
        widget.set_text(text)
        self.set_widget_class(widget, klass)
# ============================================================
# Hauptanwendung
# ============================================================


# ============================================================
# Wipe Auto – kompakt im gemeinsamen Network/Wipe-Fenster
# ============================================================
WIPE_VERSION = "3.32"
WIPE_DISK = "/dev/nvme0n1"
BATTERY_BAD_BELOW = 75.0

def wipe_run(args, timeout=8, sudo=False):
    cmd = (["sudo", "-n"] if sudo else []) + list(args)
    try:
        p = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            env=ENV_C,
        )
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except Exception as exc:
        return 99, "", str(exc)

def wipe_compact_battery_time(seconds):
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


def wipe_parse_upower_time(value):
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


def wipe_battery_power_w_sysfs(battery_name):
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
        return power_now / 1_000_000.0

    current_now = number("current_now")
    voltage_now = number("voltage_now")
    if (
        current_now is not None
        and voltage_now is not None
        and current_now >= 0
        and voltage_now > 0
    ):
        return (current_now * voltage_now) / 1_000_000_000_000.0
    return None


def wipe_format_battery_power(power_w, state):
    if power_w is None:
        return ""
    try:
        power_w = abs(float(power_w))
    except Exception:
        return ""
    if power_w < 0.05:
        return ""
    if (state or "").strip().lower() == "discharging":
        return f"- {power_w:.1f}W"
    return f"{power_w:.1f}W"


def wipe_battery_info():
    rc, out, _ = wipe_run(["upower", "-e"])
    if rc != 0:
        return None, None, None, None
    bat = next((line.strip() for line in out.splitlines() if "BAT" in line), None)
    if not bat:
        return None, None, None, None
    rc, info, _ = wipe_run(["upower", "-i", bat])
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
            time_to_empty = wipe_parse_upower_time(m.group(1))

        m = re.match(r"\s*time to full:\s*(.+?)\s*$", line, re.I)
        if m:
            time_to_full = wipe_parse_upower_time(m.group(1))

        m = re.match(r"\s*energy-rate:\s*([0-9.,]+)\s*W\s*$", line, re.I)
        if m:
            try:
                power_w = float(m.group(1).replace(",", "."))
            except Exception:
                power_w = None

    if power_w is None:
        battery_name = bat.rsplit("/", 1)[-1]
        if battery_name.startswith("battery_"):
            battery_name = battery_name[len("battery_"):]
        power_w = wipe_battery_power_w_sysfs(battery_name)

    remaining = None
    if state in {"discharging", "pending-discharge"}:
        remaining = time_to_empty
    elif state in {"charging", "pending-charge"}:
        remaining = time_to_full

    return health, state, wipe_compact_battery_time(remaining), power_w

def wipe_disk_details():
    if not Path(WIPE_DISK).exists():
        return None
    rc, out, _ = wipe_run(["lsblk", "-dn", "-o", "SIZE,MODEL", WIPE_DISK])
    if rc != 0:
        return {"size": "--", "model": "--"}
    parts = out.split(None, 1)
    return {
        "size": parts[0] if parts else "--",
        "model": parts[1].strip() if len(parts) > 1 else "--",
    }

def wipe_disk_is_clean():
    rc, sig, err = wipe_run(["wipefs", "-n", WIPE_DISK], timeout=10, sudo=True)
    if rc != 0:
        return False, err or "wipefs -n fehlgeschlagen"
    if sig.strip():
        return False, "Signaturen vorhanden"
    rc, out, err = wipe_run(["lsblk", "-nr", "-o", "NAME,TYPE", WIPE_DISK])
    if rc != 0:
        return False, err or "lsblk fehlgeschlagen"
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    if any(line.split()[-1] == "part" for line in lines[1:]):
        return False, "Partitionen vorhanden"
    return True, ""

class WipeCompactPanel:
    def __init__(self, window):
        self.window = window
        self.wiping = False
        self.last_disk_display = None
        self.soh_alert_active = False
        self.soh_blink_on = False

        # Batterie und Datenträger sind jetzt zwei eigenständige volle Zeilen.
        # Zusammen mit LAN und WLAN ergibt das exakt:
        # LAN / WLAN / BATTERIE / DATENTRÄGER – einspaltig über die gesamte Fensterbreite.
        self.root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        self.root.set_hexpand(True)
        self.root.set_vexpand(False)

        # Batterie
        battery = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        battery.set_hexpand(True)
        battery.set_vexpand(False)
        battery.add_css_class("card")
        btitle = Gtk.Label(label="BATTERIE")
        btitle.set_xalign(0)
        btitle.add_css_class("card-title")
        battery.append(btitle)

        battery_metrics = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=4,
        )
        battery_metrics.set_hexpand(True)

        self.battery_value = Gtk.Label(label="--")
        self.battery_value.set_xalign(0.5)
        self.battery_value.set_size_request(245, -1)
        self.battery_value.set_hexpand(False)
        self.battery_value.add_css_class("wipe-big")
        battery_metrics.append(self.battery_value)

        self.battery_state = Gtk.Label(label="--")
        self.battery_state.set_xalign(0.5)
        self.battery_state.set_hexpand(True)
        self.battery_state.set_ellipsize(Pango.EllipsizeMode.END)
        self.battery_state.add_css_class("wipe-big")
        battery_metrics.append(self.battery_state)
        battery.append(battery_metrics)

        self.battery_note = Gtk.Label(label="")
        self.battery_note.set_xalign(0)
        self.battery_note.set_wrap(True)
        self.battery_note.add_css_class("note")
        battery.append(self.battery_note)
        self.root.append(battery)

        # Datenträger
        disk = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        disk.set_hexpand(True)
        disk.set_vexpand(False)
        disk.add_css_class("card")
        dhead = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        dtitle = Gtk.Label(label="DATENTRÄGER")
        dtitle.set_xalign(0)
        dtitle.set_hexpand(True)
        dtitle.add_css_class("card-title")
        self.disk_badge = Gtk.Label(label="CHECKING")
        self.disk_badge.set_xalign(1)
        self.disk_badge.add_css_class("ssd-status")
        dhead.append(dtitle)
        dhead.append(self.disk_badge)
        disk.append(dhead)

        # Datenträger/Modell links und WIPE-Bedienung rechts in EINER Zeile.
        disk_action_row = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=6,
        )
        disk_action_row.set_hexpand(True)

        self.disk_value = Gtk.Label(label="--")
        self.disk_value.set_xalign(0)
        self.disk_value.set_hexpand(True)
        self.disk_value.set_wrap(False)
        self.disk_value.set_ellipsize(Pango.EllipsizeMode.END)
        self.disk_value.set_max_width_chars(70)
        self.disk_value.add_css_class("disk-result")
        disk_action_row.append(self.disk_value)

        self.action_area = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=4,
        )
        self.action_area.set_halign(Gtk.Align.END)

        self.wipe_button = Gtk.Button(label="LÖSCHEN")
        self.wipe_button.add_css_class("danger-action")
        self.wipe_button.connect("clicked", self.on_wipe_clicked)
        self.wipe_button.connect(
            "notify::has-focus",
            self.on_action_focus_changed,
        )
        self.action_area.append(self.wipe_button)
        disk_action_row.append(self.action_area)
        disk.append(disk_action_row)

        self.disk_note = Gtk.Label(label="")
        self.disk_note.set_xalign(0)
        self.disk_note.set_wrap(True)
        self.disk_note.add_css_class("note")
        disk.append(self.disk_note)

        self.root.append(disk)

        self.refresh()
        GLib.timeout_add_seconds(1, self.refresh_battery_timer)
        # Unter 75 % SoH blinkt das linke SoH-Feld wieder rot.
        GLib.timeout_add(450, self.update_soh_blink)

    @staticmethod
    def set_class(widget, klass):
        for c in ("good", "bad", "warn", "neutral", "live"):
            widget.remove_css_class(c)
        widget.add_css_class(klass)

    def refresh_battery(self):
        health, state, remaining, power_w = wipe_battery_info()
        power_text = wipe_format_battery_power(power_w, state)

        self.set_soh_alert(
            health is not None and health < BATTERY_BAD_BELOW
        )

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

        # Dieselben deutschen UPower-Zustände wie im Standalone-Wipe.
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

        self.battery_state.set_text(" · ".join(parts))
        self.set_class(self.battery_state, state_class)

    def set_soh_alert(self, active):
        active = bool(active)
        if active == self.soh_alert_active:
            return

        self.soh_alert_active = active
        self.soh_blink_on = active

        if active:
            self.battery_value.add_css_class("soh-alert")
        else:
            self.battery_value.remove_css_class("soh-alert")

    def update_soh_blink(self):
        if self.window is None:
            return False

        if not self.soh_alert_active:
            self.soh_blink_on = False
            self.battery_value.remove_css_class("soh-alert")
            return True

        self.soh_blink_on = not self.soh_blink_on
        if self.soh_blink_on:
            self.battery_value.add_css_class("soh-alert")
        else:
            self.battery_value.remove_css_class("soh-alert")

        return True

    def refresh_battery_timer(self):
        if self.window is None:
            return False
        self.refresh_battery()
        return True

    def refresh(self):
        self.refresh_battery()
        details = wipe_disk_details()
        if details is None:
            self.disk_badge.set_text("NOT FOUND")
            self.set_class(self.disk_badge, "warn")
            self.disk_value.set_text("SSD NICHT GEFUNDEN")
            self.set_class(self.disk_value, "warn")
            self.disk_note.set_text(f"{WIPE_DISK} nicht vorhanden.")
            self.wipe_button.set_sensitive(False)
        else:
            self.disk_badge.set_text("BEREIT")
            self.set_class(self.disk_badge, "neutral")
            self.last_disk_display = f"{details['size']} • {details['model']}"
            self.disk_value.set_text(self.last_disk_display)

            # Datenträger erkannt, aber noch nicht gelöscht: orange Hinweisstatus.
            # WIRD GELÖSCHT bleibt Blau, erfolgreicher Abschluss Grün, Fehler Rot.
            self.set_class(self.disk_value, "warn")

            self.disk_note.set_text("Bereit zum Löschen.")
            self.wipe_button.set_sensitive(True)

    def clear_actions(self):
        child = self.action_area.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            self.action_area.remove(child)
            child = nxt

    def restore_wipe_button(self):
        self.clear_actions()
        self.action_area.set_halign(Gtk.Align.END)
        self.action_area.set_hexpand(False)
        self.action_area.append(self.wipe_button)
        self.wipe_button.set_sensitive(True)
        self.window.set_default_widget(self.wipe_button)

    def on_wipe_clicked(self, button):
        if self.wiping:
            return
        self.clear_actions()
        self.action_area.set_halign(Gtk.Align.END)
        self.action_area.set_hexpand(False)

        warning = Gtk.Label(label="WIRKLICH LÖSCHEN?")
        warning.set_xalign(0)
        warning.set_hexpand(False)
        warning.add_css_class("confirm-warning")

        cancel = Gtk.Button(label="ABBRECHEN")
        cancel.connect("clicked", self.on_cancel)
        yes = Gtk.Button(label="JA")
        yes.add_css_class("confirm")
        yes.connect("clicked", self.on_confirm)
        yes.connect(
            "notify::has-focus",
            self.on_action_focus_changed,
        )

        self.action_area.append(warning)
        self.action_area.append(cancel)
        self.action_area.append(yes)
        self.window.set_default_widget(yes)
        yes.grab_focus()

        self.disk_badge.set_text("BESTÄTIGEN")
        self.set_class(self.disk_badge, "warn")

    def on_cancel(self, button):
        if self.wiping:
            return
        self.restore_wipe_button()
        self.refresh()
        GLib.idle_add(self.focus_wipe_button)

    def on_confirm(self, button):
        if self.wiping:
            return
        self.wiping = True
        self.clear_actions()
        self.disk_badge.set_text("WIRD GELÖSCHT")
        self.set_class(self.disk_badge, "live")
        self.disk_value.set_text(
            (self.last_disk_display + " • Wird gelöscht …")
            if self.last_disk_display else "SSD WIRD GELÖSCHT …"
        )
        self.set_class(self.disk_value, "live")
        self.disk_note.set_text("Bitte warten.")
        threading.Thread(target=self.wipe_worker, daemon=True).start()

    def wipe_worker(self):
        if not Path(WIPE_DISK).exists():
            GLib.idle_add(self.finish_error, f"{WIPE_DISK} nicht gefunden.")
            return

        rc, out, _ = wipe_run(["lsblk", "-nrpo", "NAME,TYPE", WIPE_DISK])
        if rc == 0:
            children = []
            for line in out.splitlines()[1:]:
                parts = line.split()
                if len(parts) >= 2 and parts[-1] == "part":
                    children.append(parts[0])
            for part in reversed(children):
                wipe_run(["umount", part], timeout=10, sudo=True)
                wipe_run(["fuser", "-k", part], timeout=10, sudo=True)

        wipe_run(["umount", WIPE_DISK], timeout=10, sudo=True)
        wipe_run(["fuser", "-k", WIPE_DISK], timeout=10, sudo=True)

        rc, _, err = wipe_run(["wipefs", "-a", WIPE_DISK], timeout=30, sudo=True)
        if rc != 0:
            GLib.idle_add(self.finish_error, err or "wipefs fehlgeschlagen")
            return

        wipe_run(["partprobe", WIPE_DISK], timeout=15, sudo=True)
        clean, reason = wipe_disk_is_clean()
        if not clean:
            GLib.idle_add(self.finish_error, reason)
            return

        GLib.idle_add(self.finish_success)

    def finish_success(self):
        self.wiping = False
        self.disk_badge.set_text("GELÖSCHT")
        self.set_class(self.disk_badge, "good")
        self.disk_value.set_text(
            (self.last_disk_display + " • Erfolgreich gelöscht")
            if self.last_disk_display else "Erfolgreich gelöscht"
        )
        self.set_class(self.disk_value, "good")
        self.disk_note.set_text("Keine Signaturen/Partitionen mehr erkannt.")
        self.clear_actions()
        return False

    def finish_error(self, message):
        self.wiping = False
        self.disk_badge.set_text("ERROR")
        self.set_class(self.disk_badge, "bad")
        if self.last_disk_display:
            self.disk_value.set_text(
                self.last_disk_display + " • Löschen fehlgeschlagen"
            )
        else:
            self.disk_value.set_text("Löschen fehlgeschlagen")
        self.set_class(self.disk_value, "bad")
        self.disk_note.set_text(str(message))
        self.restore_wipe_button()
        return False

    def on_action_focus_changed(self, widget, _pspec):
        try:
            focused = bool(widget.get_property("has-focus"))
        except Exception:
            focused = False
        if focused:
            widget.add_css_class("keyboard-focus")
        else:
            widget.remove_css_class("keyboard-focus")

    def focus_wipe_button(self):
        if not self.wiping and self.wipe_button.get_sensitive():
            self.window.set_default_widget(self.wipe_button)
            try:
                self.window.set_focus(self.wipe_button)
            except Exception:
                pass
            self.wipe_button.grab_focus()
        return False


class NetworkCheckApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="com.david.NetworkCheck")

        self.window = None
        self.cards = {}
        self.stop_event = threading.Event()
        self.test_queue = queue.Queue()
        self.pending = set()
        self.testing_kinds = set()
        self.testing_ifaces = {}
        self.current_proc = {"lan": None, "wifi": None}
        self.proc_lock = threading.Lock()

        self.last_connected = set()
        self.last_default = None
        self.last_lan_link = {}
        self.max_wifi_link = {}
        self.initial_scan_done = False
        # Ergebnisse bleiben während der gesamten Programmsitzung erhalten.
        self.results = {
            "lan": {
                "iface": None,
                "link": None,
                "ping": None,
                "ping_ok": None,
                "down": None,
                "up": None,
                "tested": False,
                "passed": None,
            },
            "wifi": {
                "iface": None,
                "link": None,
                "ping": None,
                "ping_ok": None,
                "down": None,
                "up": None,
                "tested": False,
                "passed": None,
            },
        }
    # --------------------------------------------------------
    # GUI
    # --------------------------------------------------------

    def do_activate(self):
        if self.window:
            self.window.present()
            # Wichtig: Das Fenster kann bereits aktiv sein. Dann gibt es kein
            # neues notify::is-active-Signal. WIPE SSD deshalb bei jeder
            # erneuten GApplication-Aktivierung ausdrücklich neu fokussieren.
            if hasattr(self, "wipe_panel"):
                GLib.idle_add(self.wipe_panel.focus_wipe_button)
                self._wipe_focus_attempts = 0
                GLib.timeout_add(120, self.ensure_wipe_focus_after_start)
            return

        self.install_css()

        self.window = Gtk.ApplicationWindow(application=self)
        self.window.set_title("Network Check v2.28 + Wipe Auto v3.32")
        self.window.set_default_size(960, 520)

        # Einheitliche Titelleiste: Name mittig, gemeinsamer REFRESH rechts.
        self.header_bar = Gtk.HeaderBar()
        self.header_bar.set_show_title_buttons(True)

        title_label = Gtk.Label(label="Network Check v2.28 + Wipe Auto v3.32")
        title_label.add_css_class("title")
        self.header_bar.set_title_widget(title_label)

        self.header_refresh_button = Gtk.Button(label="REFRESH")
        self.header_refresh_button.add_css_class("action")
        self.header_refresh_button.add_css_class("header-refresh")
        self.header_refresh_button.set_focusable(False)
        self.header_refresh_button.connect("clicked", self.on_refresh_all)
        self.header_bar.pack_end(self.header_refresh_button)

        self.window.set_titlebar(self.header_bar)

        # Das kombinierte Fenster enthält jetzt WIPE SSD. Sobald es vom
        # Kiosk/Benutzer in den Vordergrund geholt wird, bekommt WIPE SSD
        # wieder automatisch den Tastaturfokus, damit ENTER wie früher direkt
        # den Wipe-Dialog startet.
        self.window.connect("notify::is-active", self.on_window_active_changed)

        key_controller = Gtk.EventControllerKey.new()
        key_controller.connect("key-pressed", self.on_key_pressed)
        self.window.add_controller(key_controller)

        # Gemeinsames Fenster ohne zusätzliche Refresh-Zeile im Inhalt.
        # REFRESH sitzt jetzt ausschließlich in der Titelleiste.
        shell = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        shell.set_margin_top(4)
        shell.set_margin_bottom(4)
        shell.set_margin_start(4)
        shell.set_margin_end(4)

        # Einspaltiges 4-Zeilen-Layout über die komplette Fensterbreite:
        # 1. LAN
        # 2. WLAN
        # 3. BATTERY
        # 4. SSD
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        content.set_hexpand(True)
        content.set_vexpand(True)

        # global_status bleibt intern für die bestehende Testlogik,
        # wird aber bewusst nicht angezeigt.
        self.global_status = Gtk.Label(label="Starting …")

        self.cards["lan"] = ConnectionCard("LAN")
        self.cards["wifi"] = ConnectionCard("WLAN")

        for key in ("lan", "wifi"):
            self.cards[key].root.set_hexpand(True)
            self.cards[key].root.set_vexpand(False)

        content.append(self.cards["lan"].root)
        content.append(self.cards["wifi"].root)

        self.wipe_panel = WipeCompactPanel(self.window)
        self.wipe_panel.root.set_size_request(0, -1)
        self.wipe_panel.root.set_hexpand(True)
        self.wipe_panel.root.set_vexpand(False)
        content.append(self.wipe_panel.root)

        shell.append(content)

        self.window.set_child(shell)
        self.window.present()

        # Beim Start mehrmals kurz nachfassen. Unter Wayland/Tiling Assistant
        # kann das Fenster erst einige Millisekunden nach present() wirklich
        # aktiv werden. Das macht den WIPE-SSD-Fokus beim Kioskstart robust.
        self._wipe_focus_attempts = 0
        GLib.timeout_add(180, self.ensure_wipe_focus_after_start)

        log("Network Check gestartet.")

        # Zwei Worker erlauben LAN- und WLAN-Test gleichzeitig.
        for worker_no in range(2):
            threading.Thread(
                target=self.worker,
                name=f"network-check-worker-{worker_no + 1}",
                daemon=True,
            ).start()
        # Zustandsüberwachung. Kein fester Start-Sleep:
        # die App reagiert, sobald NetworkManager einen Zustand meldet.
        GLib.timeout_add(750, self.poll_network)

    def on_window_active_changed(self, window, _pspec):
        try:
            active = bool(window.get_property("is-active"))
        except Exception:
            active = False
        if active and hasattr(self, "wipe_panel"):
            GLib.idle_add(self.wipe_panel.focus_wipe_button)

    def ensure_wipe_focus_after_start(self):
        if self.window is None or not hasattr(self, "wipe_panel"):
            return False

        self._wipe_focus_attempts = getattr(self, "_wipe_focus_attempts", 0) + 1

        # Fokus bei jedem Versuch setzen. Das funktioniert auch dann, wenn
        # das Fenster bereits aktiv war und deshalb kein is-active-Signal
        # mehr ausgelöst wurde.
        self.wipe_panel.focus_wipe_button()

        try:
            active = bool(self.window.get_property("is-active"))
        except Exception:
            active = False

        try:
            focused = bool(
                self.wipe_panel.wipe_button.get_property("has-focus")
            )
        except Exception:
            focused = False

        if active and focused:
            return False

        # Bis ca. 5,4 Sekunden nachfassen. Zusätzlich aktiviert der Kiosk
        # das Fenster am Ende noch einmal per gapplication + AT-SPI.
        return self._wipe_focus_attempts < 45

    def install_css(self):
        css = b"""
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
        headerbar button {
            min-height: 20px;
            min-width: 20px;
            padding: 0px 4px;
            margin-top: 0px;
            margin-bottom: 0px;
        }
        headerbar button.header-refresh {
            min-height: 20px;
            padding: 0px 6px;
            border-radius: 6px;
            font-size: 11px;
            font-weight: 800;
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

        .global-status {
            color: #9d9da7;
            font-size: 11px;
            font-weight: 600;
        }

        .card {
            background: #191c22;
            border: 1px solid #303641;
            border-radius: 8px;
            padding: 5px 6px;
        }

        .card-title {
            font-size: 13px;
            font-weight: 800;
        }
        .mac-error {
            color: #ff4c4c;
        }
        .mac-warning {
            color: #f5a623;
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

        .ssd-status {
            background: transparent;
            border: none;
            padding: 0px 1px;
            font-size: 12px;
            font-weight: 800;
        }

        .metric {
            background: #111318;
            border-radius: 8px;
            padding: 4px 6px;
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

        .wipe-big {
            background: #111318;
            border: 1px solid transparent;
            border-radius: 8px;
            padding: 4px 6px;
            font-size: 17px;
            font-weight: 800;
        }

        .wipe-big.soh-alert {
            background: #ff4c4c;
            color: #f4f4f5;
            border-color: #ff4c4c;
        }

        .disk-result {
            background: #111318;
            border: 1px solid transparent;
            border-radius: 8px;
            padding: 4px 6px;
            font-size: 17px;
            font-weight: 800;
        }

        button.danger-action {
            font-size: 12px;
            font-weight: 800;
            padding: 4px 10px;
            border-radius: 8px;
        }

        /* Clear keyboard focus, matching the old standalone Wipe Auto. */
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
        }

        button.confirm.keyboard-focus,
        button.confirm:focus {
            background: #5aa2ff;
            color: #f4f4f5;
            border-color: #5aa2ff;
            outline: 3px solid #5aa2ff;
            outline-offset: 2px;
        }
        """
        provider = Gtk.CssProvider()
        provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )
    # --------------------------------------------------------
    # Netzwerkzustand
    # --------------------------------------------------------

    def best_device(self, device_list):
        if not device_list:
            return None
        return device_list[0]

    def poll_network(self):
        if self.stop_event.is_set():
            return False

        devices = get_devices()
        default_iface = get_default_iface()
        lan = self.best_device(devices["ethernet"])
        wifi = self.best_device(devices["wifi"])

        current_connected = set()
        iface_to_kind = {}

        for dev in devices["ethernet"]:
            iface_to_kind[dev["iface"]] = "lan"
            if dev["connected"]:
                current_connected.add(dev["iface"])

        for dev in devices["wifi"]:
            iface_to_kind[dev["iface"]] = "wifi"
            if dev["connected"]:
                current_connected.add(dev["iface"])
        self.refresh_card_presence("lan", lan, default_iface)
        self.refresh_card_presence("wifi", wifi, default_iface)

        # Beim ersten Scan alle verbundenen LAN-/WLAN-Interfaces einplanen.
        # Mit zwei Workern laufen LAN und WLAN parallel.
        if not self.initial_scan_done:
            self.initial_scan_done = True
            self.last_connected = set(current_connected)
            self.last_default = default_iface
            for iface in sorted(current_connected):
                kind = iface_to_kind.get(iface)
                if kind:
                    self.enqueue_test(iface, kind, "initial connected interface")
        else:
            # Neu verbundene Interfaces sofort testen, unabhängig davon, ob
            # sie gerade die Default-Route stellen.
            for iface in sorted(current_connected - self.last_connected):
                kind = iface_to_kind.get(iface)
                if kind:
                    self.enqueue_test(iface, kind, "interface connected")

            # Ein reiner Wechsel der Default-Route startet KEINEN neuen
            # Speedtest mehr. Beispiel: LAN wird nach abgeschlossenem LAN/WLAN-
            # Test abgezogen und WLAN wird dadurch Default. Das bestehende
            # WLAN-Ergebnis muss erhalten bleiben. Neue Tests werden nur durch
            # echte Neuverbindungen (oben) oder relevante Link-Änderungen
            # desselben Adapters ausgelöst.

            # LAN-Link-Speed-Wechsel ist wichtig:
            # z.B. 1000 -> 100 Mbps bei Stecker/Kontaktproblem.
            for dev in devices["ethernet"]:
                iface = dev["iface"]
                if not dev["connected"]:
                    continue

                speed = ethernet_link_speed(iface)
                previous = self.last_lan_link.get(iface)
                self.last_lan_link[iface] = speed
                if (
                    previous is not None
                    and speed is not None
                    and int(previous) != int(speed)
                ):
                    log(f"LAN Link-Speed geändert: {iface}: {previous} -> {speed} Mbps")
                    self.enqueue_test(iface, "lan", "LAN link changed")

            self.last_connected = set(current_connected)
            self.last_default = default_iface
        return True

    def refresh_card_presence(self, kind, dev, default_iface):
        card = self.cards[kind]
        result = self.results[kind]
        if dev is None:
            card.set_title_mac(None, adapter_present=False)
            card.interface_label.set_text("Interface: --")
            if kind not in self.testing_kinds:
                card.set_state("NICHT GEFUNDEN", "warn")
                card.note_label.set_text(
                    "Kein Adapter erkannt – nicht verbaut oder prüfen."
                )
            return

        iface = dev["iface"]
        mac = iface_mac(iface)
        card.set_title_mac(mac)
        is_default = iface == default_iface
        suffix = " • AKTIV" if is_default else ""
        card.interface_label.set_text(f"Interface: {iface}{suffix}")

        if not dev["connected"]:
            if kind not in self.testing_kinds:
                card.set_state("NICHT VERBUNDEN", "warn")
                card.note_label.set_text(
                    "Adapter vorhanden, aktuell aber nicht verbunden."
                )
            return
        # Sichtbaren LINK-Wert nur für die Verbindung aktualisieren,
        # die gerade wirklich getestet wird.
        if kind in self.testing_kinds:
            speed = self.best_link_speed(iface, kind, link_speed(iface, kind))

            if speed is not None:
                result["link"] = speed
                result["iface"] = iface
                if kind == "lan":
                    klass = "good" if speed >= LAN_LINK_MIN else "bad"
                else:
                    klass = "good" if speed >= WIFI_LINK_MIN else "bad"

                card.set_metric("link", format_mbps(speed), klass)
        # Wenn gerade nicht getestet wird, vorheriges Testergebnis erhalten.
        if kind not in self.testing_kinds:
            if result["tested"]:
                self.apply_final_state(kind)
            else:
                card.set_state("VERBUNDEN", "neutral")
                card.note_label.set_text("Bereit für Messung.")

    # --------------------------------------------------------
    # Queue / Buttons
    # --------------------------------------------------------
    def best_link_speed(self, iface, kind, speed):
        if speed is None:
            return None

        if kind != "wifi":
            return speed

        previous = self.max_wifi_link.get(iface)

        if previous is None or speed > previous:
            self.max_wifi_link[iface] = speed
            log(
                f"WLAN neuer maximaler LINK {iface}: "
                f"{speed} Mbps"
            )

        return self.max_wifi_link[iface]
    def enqueue_test(self, iface, kind, reason):
        key = (iface, kind)

        if key in self.pending:
            return
        if kind in self.testing_kinds:
            return

        self.pending.add(key)
        self.test_queue.put((iface, kind, reason))
        log(f"Test eingeplant: {kind.upper()} {iface} ({reason})")

    def reset_refresh_values(self, devices):
        """Alle sichtbaren und internen Speedtest-Werte sofort verwerfen.

        REFRESH soll auf den ersten Blick zeigen, dass wirklich neu gemessen
        wird. Deshalb werden LINK/PING/DOWNLOAD/UPLOAD beider Karten direkt auf
        ``--`` gesetzt und alte Ergebniswerte nicht in den neuen Test
        übernommen. Hardware-/MAC-/Interface-Erkennung bleibt erhalten.
        """
        for kind in ("lan", "wifi"):
            result = self.results[kind]
            result["iface"] = None
            result["link"] = None
            result["ping"] = None
            result["ping_ok"] = None
            result["down"] = None
            result["up"] = None
            result["tested"] = False
            result["passed"] = None

            card = self.cards[kind]
            card.set_metric("link", "--", "warn")
            card.set_metric("ping", "--", "warn")
            card.set_metric("down", "--", "warn")
            card.set_metric("up", "--", "warn")

            connected = any(
                dev["connected"]
                for dev in devices["ethernet" if kind == "lan" else "wifi"]
            )
            if connected:
                card.set_state("REFRESH", "live")
                card.note_label.set_text("Neue Messung wird gestartet …")

        # WLAN-LINK ist absichtlich ein Maximum während eines einzelnen
        # Tests. Bei REFRESH muss dieses Maximum ebenfalls neu beginnen.
        self.max_wifi_link.clear()
        self.global_status.set_text("Messwerte gelöscht · neue Tests werden gestartet …")

    def on_refresh_all(self, button):
        # Ein gemeinsamer REFRESH für das komplette obere linke Fenster.
        #
        # Wenn gerade die WIPE-Sicherheitsabfrage sichtbar ist, soll REFRESH
        # gleichzeitig wieder den normalen WIPE-SSD-Button einblenden.
        # Einen bereits laufenden Löschvorgang niemals unterbrechen/resetten.
        if not self.wipe_panel.wiping:
            self.wipe_panel.restore_wipe_button()

        self.wipe_panel.refresh()

        if not self.wipe_panel.wiping:
            GLib.idle_add(self.wipe_panel.focus_wipe_button)

        self.on_test_clicked(button)

    def on_test_clicked(self, button):
        devices = get_devices()

        # Zuerst ALLE bisherigen Werte sichtbar und intern löschen. Erst
        # danach neue Tests einplanen, damit der REFRESH sofort erkennbar ist.
        self.reset_refresh_values(devices)

        scheduled = 0

        for dev in devices["ethernet"]:
            if dev["connected"]:
                self.enqueue_test(dev["iface"], "lan", "manual REFRESH")
                scheduled += 1

        for dev in devices["wifi"]:
            if dev["connected"]:
                self.enqueue_test(dev["iface"], "wifi", "manual REFRESH")
                scheduled += 1

        if scheduled == 0:
            self.global_status.set_text("Keine LAN/WLAN-Verbindung vorhanden.")
        else:
            self.global_status.set_text("LAN/WLAN-Tests parallel gestartet.")

    # --------------------------------------------------------
    # Worker
    # --------------------------------------------------------
    def worker(self):
        while not self.stop_event.is_set():
            try:
                iface, kind, reason = self.test_queue.get(timeout=0.5)
            except queue.Empty:
                continue

            self.pending.discard((iface, kind))

            if self.stop_event.is_set():
                break
            # Ist Interface immer noch verbunden?
            devices = get_devices()
            typ = "ethernet" if kind == "lan" else "wifi"
            still_connected = any(
                d["iface"] == iface and d["connected"]
                for d in devices[typ]
            )

            if not still_connected:
                log(f"Test übersprungen, nicht mehr verbunden: {iface}")
                continue

            if kind in self.testing_kinds:
                continue

            self.testing_kinds.add(kind)
            self.testing_ifaces[kind] = iface
            try:
                self.run_full_test(iface, kind, reason)
            except Exception as e:
                log(f"Testfehler {iface}: {e!r}")
                GLib.idle_add(self.mark_test_error, kind, iface, str(e))
            finally:
                self.testing_kinds.discard(kind)
                self.testing_ifaces.pop(kind, None)
    def run_full_test(self, iface, kind, reason):
        log(f"START {kind.upper()} {iface} ({reason})")

        result = self.results[kind]
        result["iface"] = iface
        result["ping"] = None
        result["ping_ok"] = None

        # 1) LINK sofort lesen.
        current_link = self.best_link_speed(
            iface,
            kind,
            link_speed(iface, kind),
        )
        if current_link is not None:
            result["link"] = current_link
            GLib.idle_add(
                self.update_link,
                kind,
                current_link,
            )

        if self.stop_event.is_set():
            return

        # 2) PING – bewusst sehr kurz, danach sofort Speedtest.
        GLib.idle_add(
            self.mark_ping_testing,
            kind,
            iface,
        )
        ping_ms = self.measure_ping(iface)

        result["ping"] = ping_ms
        result["ping_ok"] = ping_ms is not None

        GLib.idle_add(
            self.update_ping_result,
            kind,
            ping_ms,
        )

        if self.stop_event.is_set():
            return

        # 3) DOWNLOAD
        GLib.idle_add(
            self.mark_testing,
            kind,
            iface,
            "DOWNLOAD",
        )
        down = self.measure_phase(
            iface,
            kind,
            "download",
        )

        if self.stop_event.is_set():
            return

        result["down"] = down
        GLib.idle_add(
            self.update_phase_final_value,
            kind,
            "down",
            down,
        )

        # 4) UPLOAD
        GLib.idle_add(
            self.mark_testing,
            kind,
            iface,
            "UPLOAD",
        )
        up = self.measure_phase(
            iface,
            kind,
            "upload",
        )

        if self.stop_event.is_set():
            return

        result["up"] = up
        GLib.idle_add(
            self.update_phase_final_value,
            kind,
            "up",
            up,
        )

        result["iface"] = iface
        result["down"] = down
        result["up"] = up
        result["tested"] = True

        # Link nach dem Test nochmals lesen.
        final_link = self.best_link_speed(
            iface,
            kind,
            link_speed(iface, kind),
        )
        if final_link is not None:
            result["link"] = final_link

        result["passed"] = self.result_passes(kind)

        log(
            f"FERTIG {kind.upper()} {iface}: "
            f"Link={result['link']} Mbps, "
            f"Ping={result['ping']} ms, "
            f"PingOK={result['ping_ok']}, "
            f"Down={down:.1f} Mbps, Up={up:.1f} Mbps, "
            f"PASS={result['passed']}"
        )
        GLib.idle_add(
            self.apply_result_to_ui,
            kind,
        )

    # --------------------------------------------------------
    # Sehr schneller PING vor dem Speedtest
    # --------------------------------------------------------

    def measure_ping(self, iface):
        """Ein ICMP-Paket pro Ziel; Rückgabe = Latenz in ms oder None.

        Normalfall: erster Host antwortet nach wenigen Millisekunden.
        Nur bei Ausfall wird ein zweiter Host versucht. So bleibt der
        Vorabtest schnell und ist trotzdem weniger anfällig gegen einen
        einzelnen nicht erreichbaren Zielhost.
        """
        for target in PING_TARGETS:
            if self.stop_event.is_set():
                return None

            try:
                p = subprocess.run(
                    [
                        "ping",
                        "-4",
                        "-n",
                        "-I", iface,
                        "-c", "1",
                        "-W", str(PING_TIMEOUT_SECONDS),
                        target,
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=PING_TIMEOUT_SECONDS + 0.5,
                    env=ENV_C,
                )
            except Exception as exc:
                log(f"PING {iface} -> {target}: Fehler {exc!r}")
                continue

            if p.returncode != 0:
                log(f"PING {iface} -> {target}: keine Antwort")
                continue

            match = re.search(
                r"time[=<]\s*([0-9]+(?:\.[0-9]+)?)\s*ms",
                p.stdout,
                re.I,
            )
            if match:
                try:
                    latency = float(match.group(1))
                    log(
                        f"PING {iface} -> {target}: "
                        f"{latency:.1f} ms"
                    )
                    return latency
                except Exception:
                    pass

            # Antwort war erfolgreich, aber einzelne ping-Versionen liefern
            # bei extrem kleinen Zeiten ein anderes Textformat.
            log(
                f"PING {iface} -> {target}: Antwort OK, "
                "Latenz nicht parsebar"
            )
            return 0.0

        return None

    # --------------------------------------------------------
    # Bereitschaft
    # --------------------------------------------------------

    def wait_for_internet(self, iface):
        deadline = time.monotonic() + CONNECTIVITY_TIMEOUT
        while time.monotonic() < deadline and not self.stop_event.is_set():
            try:
                p = subprocess.run(
                    [
                        "curl",
                        "--interface", iface,
                        "--silent",
                        "--fail",
                        "--connect-timeout", "2",
                        "--max-time", "3",
                        "--output", "/dev/null",
                        CF_CHECK,
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    env=ENV_C,
                )
                if p.returncode == 0:
                    log(f"Internet bereit auf {iface}")
                    return True
            except Exception:
                pass
            # Zustandsbasiertes Retry, kein Start-Delay.
            for _ in range(5):
                if self.stop_event.is_set():
                    return False
                time.sleep(0.1)

        return False

    # --------------------------------------------------------
    # Speedtest
    # --------------------------------------------------------
    def launch_download_stream(self, iface, remaining, stream_no):
        # Große Datalix-Testdatei aus Frankfurt.
        # Cache-Buster nur zur Sicherheit; der Transfer wird nach 5s beendet.
        sep = "&" if "?" in DOWNLOAD_URL else "?"
        url = f"{DOWNLOAD_URL}{sep}stream={stream_no}-{time.time_ns()}"
        cmd = [
            "curl",
            "--ipv4",
            "--interface", iface,
            "--silent",
            "--show-error",
            "--fail",
            "--location",
            "--connect-timeout", "2",
            "--max-time", f"{max(0.5, remaining):.2f}",
            "--header", "Cache-Control: no-cache",
            "--output", "/dev/null",
            url,
        ]
        return subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=ENV_C,
            start_new_session=True,
        )
    def launch_upload_stream(self, iface, remaining, stream_no):
        # Cloudflares eigener Referenz-Speedtest verwendet Uploadgrößen
        # bis 50 MB. Mehrere parallele Streams vermeiden, dass eine
        # Gigabit-Leitung durch einen einzelnen TCP-Stream limitiert wird.
        shell = (
            'head -c "$4" /dev/zero | '
            'curl --interface "$1" '
            '--silent --connect-timeout 2 '
            '--max-time "$2" '
            '--output /dev/null '
            '--request POST '
            '--header "Content-Type: application/octet-stream" '
            '--header "Cache-Control: no-cache" '
            '--data-binary @- '
            '"$3"'
        )
        return subprocess.Popen(
            [
                "bash", "-c", shell,
                "_",
                iface,
                f"{max(0.5, remaining):.2f}",
                CF_UP,
                str(CF_UP_BYTES),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=ENV_C,
            start_new_session=True,
        )

    def set_current_proc(self, kind, procs):
        with self.proc_lock:
            self.current_proc[kind] = procs
    def kill_process(self, proc):
        if proc is None:
            return

        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except Exception:
            try:
                proc.terminate()
            except Exception:
                pass
        try:
            proc.wait(timeout=0.5)
        except Exception:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass

    def kill_processes(self, procs):
        if not procs:
            return
        for proc in procs:
            self.kill_process(proc)
    def kill_current_process(self):
        with self.proc_lock:
            current = dict(self.current_proc)
            self.current_proc = {"lan": None, "wifi": None}

        for procs in current.values():
            if procs is None:
                continue
            if isinstance(procs, (list, tuple)):
                self.kill_processes(procs)
            else:
                self.kill_process(procs)

    def start_parallel_streams(self, iface, kind, direction, remaining):
        procs = []
        stream_count = (
            DOWNLOAD_STREAMS
            if direction == "download"
            else UPLOAD_STREAMS
        )

        for stream_no in range(stream_count):
            if direction == "download":
                proc = self.launch_download_stream(
                    iface, remaining, stream_no
                )
            else:
                proc = self.launch_upload_stream(
                    iface, remaining, stream_no
                )
            procs.append(proc)
        self.set_current_proc(kind, procs)
        return procs

    def measure_phase(self, iface, kind, direction):
        start_t = time.monotonic()
        deadline = start_t + PHASE_SECONDS

        last_bytes = iface_counter(iface, direction)
        last_t = start_t

        # Endwert = Mittelwert der stabilisierten Live-Samples.
        # Der Hochlauf der ersten WARMUP_SECONDS wird nicht eingerechnet.
        stable_samples = []
        all_samples = []
        procs = self.start_parallel_streams(
            iface,
            kind,
            direction,
            PHASE_SECONDS,
        )

        while time.monotonic() < deadline and not self.stop_event.is_set():
            time.sleep(SAMPLE_SECONDS)

            now = time.monotonic()
            cur = iface_counter(iface, direction)

            dt = now - last_t
            delta = max(0, cur - last_bytes)
            if dt > 0:
                live = delta * 8.0 / dt / 1_000_000.0
                all_samples.append(live)

                if now - start_t >= WARMUP_SECONDS:
                    stable_samples.append(live)

                GLib.idle_add(
                    self.update_live_speed,
                    kind,
                    direction,
                    live,
                )

            last_bytes = cur
            last_t = now
            # Falls alle Transfers auf einer schnellen Leitung schon
            # komplett fertig sind, sofort neue parallele Streams starten.
            if procs and all(p.poll() is not None for p in procs):
                remaining = deadline - time.monotonic()
                if remaining > 0.35:
                    procs = self.start_parallel_streams(
                        iface,
                        kind,
                        direction,
                        remaining,
                    )
        self.kill_processes(procs)
        self.set_current_proc(kind, None)

        samples = stable_samples if stable_samples else all_samples

        # Null-/Fehlersamples nicht schönrechnen.
        useful = [v for v in samples if v > 0.05]

        if not useful:
            raise RuntimeError(f"Keine {direction}-Daten gemessen")
        # Nicht den gesamten Mittelwert verwenden:
        # Der Verbindungsaufbau am Anfang ist real, aber für unsere
        # Prüfstation interessiert die stabil erreichbare Geschwindigkeit.
        #
        # Deshalb sortieren wir die stabilisierten Samples und bilden
        # den Mittelwert aus den schnellsten 50 %. Das ist robuster als
        # einfach den Maximalwert zu nehmen.
        sorted_samples = sorted(useful, reverse=True)
        top_count = max(1, int(len(sorted_samples) * TOP_SAMPLE_FRACTION + 0.5))
        top_samples = sorted_samples[:top_count]
        raw_avg = sum(useful) / len(useful)
        avg = sum(top_samples) / len(top_samples)

        stream_count = (
            DOWNLOAD_STREAMS
            if direction == "download"
            else UPLOAD_STREAMS
        )

        log(
            f"{iface} {direction}: TOP-AVG {avg:.1f} Mbps "
            f"(Gesamt-AVG={raw_avg:.1f}, "
            f"Top={top_count}/{len(useful)} Samples, "
            f"Streams={stream_count}, Phase={PHASE_SECONDS:.1f}s)"
        )

        return avg
    # --------------------------------------------------------
    # Bewertung
    # --------------------------------------------------------

    def result_passes(self, kind):
        r = self.results[kind]

        if (
            r["link"] is None
            or r["ping_ok"] is not True
            or r["down"] is None
            or r["up"] is None
        ):
            return False

        return self.result_quality(kind) == "good"

    def metric_class(self, kind, metric, value):
        if value is None:
            return "warn"

        if metric == "link":
            target = LAN_LINK_MIN if kind == "lan" else WIFI_LINK_MIN
        elif metric == "down":
            target = (
                LAN_DOWNLOAD_MIN
                if kind == "lan"
                else WIFI_DOWNLOAD_MIN
            )
        else:
            target = (
                LAN_UPLOAD_MIN
                if kind == "lan"
                else WIFI_UPLOAD_MIN
            )

        if value >= target:
            return "good"
        if value >= target * NETWORK_WARN_FACTOR:
            return "warn"
        return "bad"

    def ping_class(self, latency):
        if latency is None:
            return "bad"
        if latency <= PING_GOOD_MAX_MS:
            return "good"
        if latency <= PING_WARN_MAX_MS:
            return "warn"
        return "bad"

    def result_quality(self, kind):
        """Gesamtqualität anhand aller vier LAN/WLAN-Werte."""
        r = self.results[kind]

        if (
            r["link"] is None
            or r["ping_ok"] is not True
            or r["down"] is None
            or r["up"] is None
        ):
            return "bad"

        classes = [
            self.metric_class(kind, "link", r["link"]),
            self.ping_class(r["ping"]),
            self.metric_class(kind, "down", r["down"]),
            self.metric_class(kind, "up", r["up"]),
        ]

        if "bad" in classes:
            return "bad"
        if "warn" in classes:
            return "warn"
        return "good"

    # --------------------------------------------------------
    # UI-Updates aus Worker
    # --------------------------------------------------------
    def mark_testing(self, kind, iface, phase):
        card = self.cards[kind]
        card.interface_label.set_text(f"Interface: {iface}")
        card.set_state(phase, "live")
        card.note_label.set_text("Speedtest läuft …")
        # Laufender Test = Blau. Bereits abgeschlossene Werte behalten
        # ihre fertige Grün/Orange/Rot-Bewertung.
        if phase == "DOWNLOAD":
            card.set_metric("down", "0.0 Mbps", "live")
        elif phase == "UPLOAD":
            card.set_metric("up", "0.0 Mbps", "live")

        self.global_status.set_text(f"{kind.upper()} {iface}: {phase}")
        return False
    def update_link(self, kind, speed):
        card = self.cards[kind]
        card.set_metric(
            "link",
            format_mbps(speed),
            self.metric_class(kind, "link", speed),
        )
        return False

    def mark_ping_testing(self, kind, iface):
        card = self.cards[kind]
        card.interface_label.set_text(f"Interface: {iface}")
        card.set_state("PING", "live")
        card.set_metric("ping", "LÄUFT", "live")
        card.note_label.set_text("Ping wird geprüft …")
        self.global_status.set_text(
            f"{kind.upper()} {iface}: PING"
        )
        return False

    def update_ping_result(self, kind, latency):
        card = self.cards[kind]

        if latency is None:
            card.set_metric("ping", "FEHLER", "bad")
            return False

        if latency < 1.0:
            text_value = "<1 ms"
        elif latency < 10.0:
            text_value = f"{latency:.1f} ms"
        else:
            text_value = f"{latency:.0f} ms"

        card.set_metric(
            "ping",
            text_value,
            self.ping_class(latency),
        )
        return False

    def update_live_speed(self, kind, direction, speed):
        card = self.cards[kind]
        metric = "down" if direction == "download" else "up"
        # Solange die Messung läuft, bleibt der Live-Wert Blau.
        # Erst der fertige Messwert wird Grün/Orange/Rot bewertet.
        card.set_metric(
            metric,
            format_mbps(speed, decimals=1),
            "live",
        )
        return False

    def update_phase_final_value(self, kind, metric, speed):
        card = self.cards[kind]
        # Nach Abschluss einer Phase sofort den gleichen Endwert einsetzen,
        # der später auch im fertigen Ergebnis stehen wird.
        card.set_metric(
            metric,
            format_mbps(speed, decimals=0),
            self.metric_class(kind, metric, speed),
        )
        return False
    def mark_test_error(self, kind, iface, error):
        card = self.cards[kind]
        card.set_state("TEST ERROR", "bad")
        card.note_label.set_text(error)
        self.global_status.set_text(f"{kind.upper()}-Test fehlgeschlagen")
        return False

    def apply_result_to_ui(self, kind):
        r = self.results[kind]
        card = self.cards[kind]
        card.set_metric(
            "link",
            format_mbps(r["link"]),
            self.metric_class(kind, "link", r["link"]),
        )

        if r["ping_ok"] is True:
            latency = r["ping"]
            if latency is None:
                ping_text = "OK"
            elif latency < 1.0:
                ping_text = "<1 ms"
            elif latency < 10.0:
                ping_text = f"{latency:.1f} ms"
            else:
                ping_text = f"{latency:.0f} ms"

            card.set_metric(
                "ping",
                ping_text,
                self.ping_class(latency),
            )
        elif r["ping_ok"] is False:
            card.set_metric("ping", "FEHLER", "bad")
        else:
            card.set_metric("ping", "--", "warn")

        card.set_metric(
            "down",
            format_mbps(r["down"], decimals=0),
            self.metric_class(kind, "down", r["down"]),
        )
        card.set_metric(
            "up",
            format_mbps(r["up"], decimals=0),
            self.metric_class(kind, "up", r["up"]),
        )

        self.apply_final_state(kind)
        self.global_status.set_text(
            f"{kind.upper()}-Test abgeschlossen • "
            f"Download {r['down']:.1f} / Upload {r['up']:.1f} Mbps"
        )

        return False

    def apply_final_state(self, kind):
        r = self.results[kind]
        card = self.cards[kind]

        if not r["tested"]:
            return

        if r["ping_ok"] is False:
            card.set_state("PING ERROR", "bad")
            card.note_label.set_text(
                "Keine ICMP-Antwort – PING-Feld prüfen."
            )
            return

        quality = self.result_quality(kind)

        if quality == "good":
            card.set_state("GETESTET", "good")
            card.note_label.set_text(
                "Alle Messwerte im guten Bereich."
            )
        elif quality == "warn":
            card.set_state("LANGSAM", "warn")
            card.note_label.set_text(
                "Mindestens ein Messwert liegt im orangenen Bereich."
            )
        else:
            card.set_state("ZU LANGSAM", "bad")
            card.note_label.set_text(
                "Mindestens ein Messwert liegt deutlich unter dem Zielbereich."
            )

    # --------------------------------------------------------
    # Ende
    # --------------------------------------------------------

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
        self.stop_event.set()
        self.kill_current_process()
        log("Network Check beendet.")
        Gtk.Application.do_shutdown(self)


app = NetworkCheckApp()
raise SystemExit(app.run(None))
PY

python3 "$TMP_PY"
NETWORK_CHECK_SCRIPT_EOF

    chmod +x "$NETWORK_CHECK_SCRIPT"

    # App-Launcher für GNOME / Tiling Assistant
    write_network_check_desktop
    # Beim ersten Installieren standardmäßig Autostart EIN.
    # Bei Updates bestehenden EIN/AUS-Zustand beibehalten.
    if [ -f "$NETWORK_CHECK_AUTOSTART" ]; then
        if grep -qiE '^Hidden=true$' "$NETWORK_CHECK_AUTOSTART" 2>/dev/null \
            || grep -qiE '^X-GNOME-Autostart-enabled=false$' "$NETWORK_CHECK_AUTOSTART" 2>/dev/null
        then
            write_network_check_autostart false
        else
            write_network_check_autostart true
        fi
    else
        write_network_check_autostart true
    fi
    # Desktop-Datenbank aktualisieren, falls vorhanden.
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
    fi
    echo
    echo "OK: Network Check installiert/aktualisiert."
    echo
    echo "Programm:"
    echo "  $NETWORK_CHECK_SCRIPT"
    echo
    echo "GNOME-App:"
    echo "  $NETWORK_CHECK_APP_DESKTOP"
    echo
    echo "Autostart:"
    echo "  $NETWORK_CHECK_AUTOSTART"
    echo
    echo "Status: $(network_check_status)"
    echo
    echo "Im Tiling Assistant sollte die Anwendung als"
    echo "  Network Check"
    echo "auftauchen."

    pause
}

enable_network_check_autostart() {
    header
    if [ ! -x "$NETWORK_CHECK_SCRIPT" ]; then
        echo "Network Check ist noch nicht installiert."
        echo "Bitte zuerst Menüpunkt 11 verwenden."
        pause
        return
    fi

    write_network_check_desktop
    write_network_check_autostart true

    echo "Network Check Autostart: AKTIVIERT"
    echo
    echo "Beim nächsten Login startet Network Check als eigenes Fenster."
    pause
}

disable_network_check_autostart() {
    header
    if [ ! -x "$NETWORK_CHECK_SCRIPT" ]; then
        echo "Network Check ist noch nicht installiert."
        pause
        return
    fi

    write_network_check_desktop
    write_network_check_autostart false

    echo "Network Check Autostart: DEAKTIVIERT"
    echo
    echo "Das Programm bleibt installiert und kann weiterhin manuell"
    echo "oder über den Tiling Assistant gestartet werden."
    pause
}

start_network_check() {
    header
    if [ ! -x "$NETWORK_CHECK_SCRIPT" ]; then
        echo "Network Check ist noch nicht installiert."
        echo "Bitte zuerst Menüpunkt 11 verwenden."
        pause
        return
    fi

    if pgrep -f '/network-check\.sh|com\.david\.NetworkCheck' >/dev/null 2>&1; then
        echo "Network Check scheint bereits zu laufen."
    else
        nohup "$NETWORK_CHECK_SCRIPT" >/dev/null 2>&1 &
        echo "Network Check gestartet."
    fi

    echo
    echo "Es läuft als separates Fenster."
    pause
}

install_wipe_auto_menu() {
    header
    echo "Wipe Auto installieren / aktualisieren"
    echo "------------------------------------------------------------"
    echo

    if install_wipe_auto_app; then
        echo
        echo "OK."
        echo "Tiling Assistant App: Wipe Auto"
        echo "App-ID: com.david.WipeAuto"
    fi

    pause
}

start_wipe_auto() {
    header
    if [ ! -x "$WIPE_AUTO_SCRIPT" ]; then
        echo "Wipe Auto ist noch nicht installiert."
        echo "Bitte zuerst Menüpunkt 15 verwenden."
        pause
        return
    fi

    nohup "$WIPE_AUTO_SCRIPT" >/dev/null 2>&1 &

    echo "Wipe Auto gestartet."
    echo "Bei einer bereits laufenden Instanz wird das vorhandene Fenster aktiviert."
    pause
}

install_hardware_check_menu() {
    header
    echo "Hardware Check installieren / aktualisieren"
    echo "------------------------------------------------------------"
    echo

    if install_hardware_check_app; then
        echo
        echo "OK."
        echo "Tiling Assistant App: Hardware Check"
        echo "App-ID: com.david.HardwareCheck"
    fi

    pause
}

start_hardware_check() {
    header
    if [ ! -x "$HARDWARE_CHECK_SCRIPT" ]; then
        echo "Hardware Check ist noch nicht installiert."
        echo "Bitte zuerst Menüpunkt 17 verwenden."
        pause
        return
    fi

    nohup "$HARDWARE_CHECK_SCRIPT" >/dev/null 2>&1 &

    echo "Hardware Check gestartet."
    echo "Bei einer bereits laufenden Instanz wird das vorhandene Fenster aktiviert."
    pause
}


install_all_menu() {
    header
    echo "ALLES AUTOMATISCH installieren / aktualisieren"
    echo "------------------------------------------------------------"
    echo
    echo "Installiert bzw. aktualisiert in einem Durchlauf:"
    echo "  • Network Check + Wipe Auto"
    echo "  • Uwuntu Kamera Test"
    echo "  • Touch-Tester"
    echo "  • Display-Test"
    echo "  • Standalone Wipe Auto"
    echo "  • Uwuntu Audio Test"
    echo "  • Hardware Check inkl. HDMI + Touchpad"
    echo "  • Helper, ydotool / AT-SPI und 4-Felder-Kiosk"
    echo

    local previous_auto_mode="${AUTO_MODE:-0}"
    AUTO_MODE=1

    local rc=0
    install_kiosk || rc=$?

    AUTO_MODE="$previous_auto_mode"

    echo
    if [ "$rc" -eq 0 ]; then
        echo "OK: Alle Uwuntu-Komponenten wurden installiert/aktualisiert."
    else
        echo "FEHLER: Die Komplettinstallation wurde nicht vollständig abgeschlossen."
    fi

    pause
    return "$rc"
}


main_menu() {
    while true; do
        header
        echo "KIOSK"
        echo "  1) ALLES AUTOMATISCH installieren/aktualisieren (alle Module + Kiosk)"
        echo "  2) 4-Felder-Kiosk jetzt testen"
        echo "  3) Kiosk-Log anzeigen"
        echo
        echo "GNOME AUTOSTART"
        echo "  4) Alle Autostarts anzeigen"
        echo "  5) Details eines Eintrags anzeigen"
        echo "  6) Autostart deaktivieren"
        echo "  7) Autostart aktivieren"
        echo "  8) Benutzer-Autostart löschen"
        echo
        echo "SYSTEMD BENUTZERDIENSTE"
        echo "  9) Aktivierte Benutzer-Services anzeigen"
        echo " 10) Benutzer-Service deaktivieren"
        echo
        echo "NETWORK CHECK  [$(network_check_status)]"
        echo " 11) Installieren / aktualisieren"
        echo " 12) Autostart aktivieren"
        echo " 13) Autostart deaktivieren"
        echo " 14) Jetzt starten"
        echo
        echo "WIPE AUTO"
        echo " 15) Installieren / aktualisieren"
        echo " 16) Jetzt starten"
        echo
        echo "HARDWARE CHECK"
        echo " 17) Installieren / aktualisieren"
        echo " 18) Jetzt starten"
        echo
        echo "  0) Beenden"
        echo
        local choice
        read -r -p "Auswahl: " choice
        case "$choice" in
            1) install_all_menu ;;
            2) test_kiosk ;;
            3) show_kiosk_log ;;
            4)
                header
                show_autostarts
                pause
                ;;
            5) show_details ;;
            6) disable_autostart ;;
            7) enable_autostart ;;
            8) delete_user_autostart ;;
            9) show_user_services ;;
            10) disable_user_service ;;
            11) install_network_check ;;
            12) enable_network_check_autostart ;;
            13) disable_network_check_autostart ;;
            14) start_network_check ;;
            15) install_wipe_auto_menu ;;
            16) start_wipe_auto ;;
            17) install_hardware_check_menu ;;
            18) start_hardware_check ;;
            0)
                echo
                echo "Beendet."
                exit 0
                ;;
            *)
                echo "Ungültige Auswahl."
                sleep 1
                ;;
        esac
    done
}

apply_update_noninteractive() {
    AUTO_MODE=1

    # install_kiosk ist jetzt der zentrale ALLES-Installer und installiert
    # Network/Wipe sowie sämtliche übrigen Module selbst.
    install_kiosk || return 1
    return 0
}

if [ "${1:-}" = "--apply-update" ]; then
    if apply_update_noninteractive; then
        exit 0
    fi
    exit 1
fi

main_menu
