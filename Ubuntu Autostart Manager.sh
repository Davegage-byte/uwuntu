#!/usr/bin/env bash
set -u

# ============================================================
# Ubuntu / GNOME Autostart Manager + 4-Tile Diagnose-Kiosk + Network Check v2.28 + Hardware Check v4.5.74 + Wipe Auto v3.32 + Audio Test v1.21
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
MANAGER_BUILD=2026090910
AUTO_MODE=0

# Die Laufzeitprogramme werden als eigenstaendige Repository-Module gepflegt.
# Bei einem vollstaendigen lokalen Checkout wird ausschliesslich diese lokale
# Quelle verwendet. Ein einzeln heruntergeladener Manager laedt alle Module
# von demselben Ref (beim U-Update: derselbe Commit-SHA wie der Manager).
MANAGER_SOURCE_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
MANAGER_SOURCE_DIR="$(dirname "$MANAGER_SOURCE_PATH")"
LOCAL_MODULE_ROOT="$MANAGER_SOURCE_DIR/modules/ubuntu-autostart-manager"
REMOTE_MODULE_BASE="https://raw.githubusercontent.com/Davegage-byte/uwuntu"
REF_API_URL="https://api.github.com/repos/Davegage-byte/uwuntu/git/ref/heads/main"
RAW_MANAGER_PATH="Ubuntu%20Autostart%20Manager.sh"
RUNTIME_MODULES_READY=0
APPLY_UPDATE_MODE=0
RUNTIME_MODULE_TRANSACTION_DIR=""

RUNTIME_MODULE_PATHS=(
    "apps/network-check.sh"
    "apps/wipe-auto-app.sh"
    "apps/audio-test.sh"
    "apps/hardware-check.sh"
    "apps/camera-test.sh"
    "apps/touch-test.sh"
    "apps/display-test.sh"
    "helpers/start-kiosk-apps.sh"
    "helpers/close-diagnostic-apps.sh"
    "helpers/force-update.sh"
)
RUNTIME_MODULE_TARGETS=(
    "$NETWORK_CHECK_SCRIPT"
    "$WIPE_AUTO_SCRIPT"
    "$AUDIO_TEST_SCRIPT"
    "$HARDWARE_CHECK_SCRIPT"
    "$CAMERA_TEST_SCRIPT"
    "$TOUCH_TEST_SCRIPT"
    "$DISPLAY_TEST_SCRIPT"
    "$KIOSK_LAUNCHER"
    "$CLOSE_APPS_SCRIPT"
    "$FORCE_UPDATE_SCRIPT"
)

mkdir -p "$USER_AUTOSTART" "$BIN_DIR" "$APP_DIR" "$HOME/.config"

runtime_module_index() {
    local wanted="$1" index
    for index in "${!RUNTIME_MODULE_PATHS[@]}"; do
        if [ "${RUNTIME_MODULE_PATHS[$index]}" = "$wanted" ]; then
            printf '%s\n' "$index"
            return 0
        fi
    done
    return 1
}

update_bootstrap_log() {
    local message="$1"
    printf '%s\n' "$message"
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" \
        >> "$HOME/uwuntu_force_update.log" 2>/dev/null || true
}

resolve_apply_update_source_ref() {
    local ref_tmp manager_tmp cache_bust latest_sha="" download_ref="main"

    # Zukuenftige Updates erhalten den exakten Ref bereits vom neuen Helper.
    # Nur der erste Wechsel von einem alten Helper benoetigt den Bootstrap.
    if [ -n "${UWUNTU_SOURCE_REF:-}" ]; then
        update_bootstrap_log "Uwuntu-Modulquelle vom Updater: $UWUNTU_SOURCE_REF"
        return 0
    fi

    command -v curl >/dev/null 2>&1 || {
        update_bootstrap_log "FEHLER: Erster modularer U-Update-Bootstrap benoetigt curl."
        return 1
    }

    ref_tmp="$(mktemp /tmp/uwuntu-bootstrap-ref.XXXXXX.json)" || return 1
    manager_tmp="$(mktemp /tmp/uwuntu-bootstrap-manager.XXXXXX.sh)" || {
        rm -f -- "$ref_tmp"
        return 1
    }
    cache_bust="$(date +%s%N)-$$"

    if curl --fail --location --silent --show-error --retry 1 --retry-delay 1 \
        --connect-timeout 6 --max-time 15 \
        --header 'Accept: application/vnd.github+json' \
        --header 'Cache-Control: no-cache, no-store, max-age=0' \
        --output "$ref_tmp" "${REF_API_URL}?uwuntu_cache_bust=${cache_bust}"
    then
        latest_sha="$(python3 - "$ref_tmp" <<'PY'
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
        if [ -z "$latest_sha" ]; then
            update_bootstrap_log "GitHub-main-Ref nicht auswertbar - ausdruecklicher RAW-main-Fallback fuer Manager und Module."
        else
            download_ref="$latest_sha"
            update_bootstrap_log "Erster modularer U-Update-Bootstrap: GitHub main Commit $latest_sha"
        fi
    else
        update_bootstrap_log "GitHub-Ref-API nicht verfuegbar - ausdruecklicher RAW-main-Fallback fuer Manager und Module."
    fi

    if ! curl --fail --location --silent --show-error --retry 2 --retry-delay 1 \
        --connect-timeout 8 --max-time 45 \
        --header 'Cache-Control: no-cache, no-store, max-age=0' \
        --output "$manager_tmp" \
        "${REMOTE_MODULE_BASE}/${download_ref}/${RAW_MANAGER_PATH}?uwuntu_cache_bust=${cache_bust}"
    then
        rm -f -- "$ref_tmp" "$manager_tmp"
        update_bootstrap_log "FEHLER: Manager-Abgleich fuer den modularen U-Update-Bootstrap fehlgeschlagen."
        return 1
    fi

    if [ ! -s "$manager_tmp" ] || ! bash -n "$manager_tmp" >/dev/null 2>&1 \
        || ! cmp -s -- "$MANAGER_SOURCE_PATH" "$manager_tmp"
    then
        rm -f -- "$ref_tmp" "$manager_tmp"
        update_bootstrap_log "FEHLER: main zeigt bereits auf einen anderen Manager; Update wird ohne Modul-Mischung abgebrochen."
        return 1
    fi

    rm -f -- "$ref_tmp" "$manager_tmp"
    UWUNTU_SOURCE_REF="$download_ref"
    export UWUNTU_SOURCE_REF
    update_bootstrap_log "Commitgenaue Modulquelle bestaetigt: $UWUNTU_SOURCE_REF"
    return 0
}

runtime_module_transaction_begin() {
    local index target

    [ -z "$RUNTIME_MODULE_TRANSACTION_DIR" ] || return 1
    RUNTIME_MODULE_TRANSACTION_DIR="$(mktemp -d /tmp/uwuntu-runtime-transaction.XXXXXX)" \
        || return 1

    for index in "${!RUNTIME_MODULE_TARGETS[@]}"; do
        target="${RUNTIME_MODULE_TARGETS[$index]}"
        if [ -e "$target" ]; then
            if ! cp -a -- "$target" "$RUNTIME_MODULE_TRANSACTION_DIR/$index.file"; then
                rm -rf -- "$RUNTIME_MODULE_TRANSACTION_DIR"
                RUNTIME_MODULE_TRANSACTION_DIR=""
                return 1
            fi
            : > "$RUNTIME_MODULE_TRANSACTION_DIR/$index.existed"
        fi
    done
}

runtime_module_transaction_commit() {
    [ -n "$RUNTIME_MODULE_TRANSACTION_DIR" ] || return 0
    rm -rf -- "$RUNTIME_MODULE_TRANSACTION_DIR"
    RUNTIME_MODULE_TRANSACTION_DIR=""
}

runtime_module_transaction_rollback() {
    local index target restored

    [ -n "$RUNTIME_MODULE_TRANSACTION_DIR" ] || return 0
    for index in "${!RUNTIME_MODULE_TARGETS[@]}"; do
        target="${RUNTIME_MODULE_TARGETS[$index]}"
        rm -f -- "${target}.new.$$" "${target}.rollback.$$"
        if [ -e "$RUNTIME_MODULE_TRANSACTION_DIR/$index.existed" ]; then
            restored="${target}.rollback.$$"
            if cp -a -- "$RUNTIME_MODULE_TRANSACTION_DIR/$index.file" "$restored"; then
                mv -f -- "$restored" "$target"
            else
                rm -f -- "$restored"
            fi
        else
            rm -f -- "$target"
        fi
    done
    rm -rf -- "$RUNTIME_MODULE_TRANSACTION_DIR"
    RUNTIME_MODULE_TRANSACTION_DIR=""
}

stage_runtime_module() {
    local relative_path="$1" staged_path="$2" source_ref="$3"
    local local_path="$LOCAL_MODULE_ROOT/$relative_path"

    # Ein expliziter Ref stammt vom U-Updater. In diesem Fall darf keine
    # danebenliegende Datei einen anderen Stand in das Update mischen.
    if [ -z "${UWUNTU_SOURCE_REF:-}" ] && [ -f "$local_path" ]; then
        cp -- "$local_path" "$staged_path" || return 1
        return 0
    fi

    command -v curl >/dev/null 2>&1 || {
        echo "FEHLER: Modul '$relative_path' fehlt lokal und curl ist nicht installiert."
        return 1
    }

    local url="${REMOTE_MODULE_BASE}/${source_ref}/modules/ubuntu-autostart-manager/${relative_path}"
    echo "Modul-Fallback von GitHub ($source_ref): $relative_path"
    curl --fail --location --silent --show-error --retry 2 --retry-delay 1 \
        --connect-timeout 8 --max-time 45 --output "$staged_path" "$url" || {
        echo "FEHLER: Modul '$relative_path' konnte nicht von GitHub geladen werden."
        return 1
    }
}

install_runtime_modules() {
    local requested=("$@") source_ref="${UWUNTU_SOURCE_REF:-main}"
    local staging rollback relative_path index target candidate backup new_file
    local -a indexes=() installed_indexes=()

    if [ "${#requested[@]}" -eq 0 ]; then
        indexes=("${!RUNTIME_MODULE_PATHS[@]}")
    else
        for relative_path in "${requested[@]}"; do
            index="$(runtime_module_index "$relative_path")" || {
                echo "FEHLER: Unbekanntes Uwuntu-Modul: $relative_path"
                return 1
            }
            indexes+=("$index")
        done
    fi

    staging="$(mktemp -d /tmp/uwuntu-modules-stage.XXXXXX)" || return 1
    rollback="$(mktemp -d /tmp/uwuntu-modules-rollback.XXXXXX)" || {
        rm -rf -- "$staging"
        return 1
    }

    # Erst alle Quellen bereitstellen und pruefen. Bis zum erfolgreichen Ende
    # dieses Blocks bleibt jede produktiv installierte Datei unangetastet.
    for index in "${indexes[@]}"; do
        relative_path="${RUNTIME_MODULE_PATHS[$index]}"
        candidate="$staging/$index.sh"
        if ! stage_runtime_module "$relative_path" "$candidate" "$source_ref" \
            || [ ! -s "$candidate" ] \
            || ! head -n 1 "$candidate" | grep -q '^#!/usr/bin/env bash' \
            || ! bash -n "$candidate" >/dev/null 2>&1
        then
            echo "FEHLER: Modulpruefung fehlgeschlagen: $relative_path"
            rm -rf -- "$staging" "$rollback"
            return 1
        fi
        chmod 0755 "$candidate" || {
            rm -rf -- "$staging" "$rollback"
            return 1
        }
    done

    # Installation pro Ziel ueber eine Datei im Zielverzeichnis. Bei einem
    # seltenen Schreibfehler werden bereits ersetzte Module zurueckgerollt.
    for index in "${indexes[@]}"; do
        target="${RUNTIME_MODULE_TARGETS[$index]}"
        candidate="$staging/$index.sh"
        backup="$rollback/$index.sh"
        new_file="${target}.new.$$"
        if [ -e "$target" ]; then
            cp -a -- "$target" "$backup" || break
        fi
        if ! cp -- "$candidate" "$new_file" || ! chmod 0755 "$new_file" \
            || ! mv -f -- "$new_file" "$target"
        then
            rm -f -- "$new_file"
            break
        fi
        installed_indexes+=("$index")
    done

    if [ "${#installed_indexes[@]}" -ne "${#indexes[@]}" ]; then
        echo "FEHLER: Modulinstallation fehlgeschlagen; bisherige Dateien werden wiederhergestellt."
        for index in "${installed_indexes[@]}"; do
            target="${RUNTIME_MODULE_TARGETS[$index]}"
            backup="$rollback/$index.sh"
            if [ -e "$backup" ]; then
                cp -a -- "$backup" "${target}.rollback.$$" \
                    && mv -f -- "${target}.rollback.$$" "$target"
            else
                rm -f -- "$target"
            fi
        done
        rm -rf -- "$staging" "$rollback"
        return 1
    fi

    rm -rf -- "$staging" "$rollback"
    return 0
}

require_runtime_module() {
    local relative_path="$1" index target
    index="$(runtime_module_index "$relative_path")" || return 1
    target="${RUNTIME_MODULE_TARGETS[$index]}"
    if [ "$RUNTIME_MODULES_READY" -eq 1 ] && [ -x "$target" ]; then
        return 0
    fi
    install_runtime_modules "$relative_path"
}

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
    # Laufzeitcode liegt als Repository-Modul vor und wird zentral installiert.
    require_runtime_module "helpers/close-diagnostic-apps.sh" || return 1

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

    # Laufzeitcode liegt als Repository-Modul vor und wird zentral installiert.
    require_runtime_module "helpers/force-update.sh" || return 1
    chmod +x "$FORCE_UPDATE_SCRIPT"
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

    # Laufzeitcode liegt als Repository-Modul vor und wird zentral installiert.
    require_runtime_module "apps/camera-test.sh" || return 1
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

    # Laufzeitcode liegt als Repository-Modul vor und wird zentral installiert.
    require_runtime_module "apps/touch-test.sh" || return 1
    chmod +x "$TOUCH_TEST_SCRIPT"
    mkdir -p "$(dirname "$TOUCH_STATE_FILE")"

    echo "OK: Touch-Tester installiert/aktualisiert."
    echo "Programm: $TOUCH_TEST_SCRIPT"
    echo "Status:   $TOUCH_STATE_FILE"
    return 0
}


install_display_test_app() {
    echo "--- Uwuntu Display-Test installieren / aktualisieren ---"

    # Laufzeitcode liegt als Repository-Modul vor und wird zentral installiert.
    require_runtime_module "apps/display-test.sh" || return 1

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

    # Laufzeitcode liegt als Repository-Modul vor und wird zentral installiert.
    require_runtime_module "apps/wipe-auto-app.sh" || return 1

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

    # Laufzeitcode liegt als Repository-Modul vor und wird zentral installiert.
    require_runtime_module "apps/audio-test.sh" || return 1

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

    echo "OK: Uwuntu Audio Test v1.21 installiert/aktualisiert."
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

    # Laufzeitcode liegt als Repository-Modul vor und wird zentral installiert.
    require_runtime_module "apps/hardware-check.sh" || return 1

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

    if [ "$APPLY_UPDATE_MODE" -eq 1 ]; then
        if ! runtime_module_transaction_begin; then
            echo "FEHLER: Runtime-Modultransaktion konnte nicht gestartet werden."
            pause
            return 1
        fi
    fi

    echo "--- Uwuntu-Laufzeitmodule vollstaendig bereitstellen ---"
    if ! install_runtime_modules; then
        echo "FEHLER: Kein Modul wurde ersetzt; die bisherige Installation bleibt erhalten."
        pause
        return 1
    fi
    RUNTIME_MODULES_READY=1

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

    # Laufzeitcode liegt als Repository-Modul vor und wird zentral installiert.
    require_runtime_module "helpers/start-kiosk-apps.sh" || return 1

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

    # Laufzeitcode liegt als Repository-Modul vor und wird zentral installiert.
    require_runtime_module "apps/network-check.sh" || return 1

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
    APPLY_UPDATE_MODE=1

    if ! resolve_apply_update_source_ref; then
        return 1
    fi

    # Auch ein unerwartetes Prozessende darf keine nur halb abgeschlossene
    # Runtime-Transaktion hinterlassen. Nach Commit ist der Handler ein No-op.
    trap 'runtime_module_transaction_rollback' EXIT

    # install_kiosk ist jetzt der zentrale ALLES-Installer und installiert
    # Network/Wipe sowie sämtliche übrigen Module selbst.
    if ! install_kiosk; then
        runtime_module_transaction_rollback
        return 1
    fi

    runtime_module_transaction_commit
    trap - EXIT
    return 0
}

if [ "${1:-}" = "--apply-update" ]; then
    if apply_update_noninteractive; then
        exit 0
    fi
    exit 1
fi

main_menu
