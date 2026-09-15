#!/usr/bin/env bash
# Uwuntu WLAN Self-Heal
# Version 1.3
#
# Ziel:
# - SSID/Profil heißt exakt "Guest".
# - WLAN wird auch bei aktivem LAN repariert, damit LAN + WLAN parallel bereitstehen.
# - LAN/WWAN/andere echte Verbindungen werden niemals getrennt oder repariert.
# - NetworkManager wird nur neu gestartet, wenn KEINE andere echte Verbindung aktiv ist.
# - Das Guest-Profil bleibt hardwareunabhängig (kein Interface-/BSSID-/MAC-Binding).
# - WLAN-Powersave ist für Guest deaktiviert.
# - Normaler NetworkManager-/wpa_supplicant-Verbindungsaufbau wird nicht unterbrochen.
# - Vor jeder erzwungenen Aktivierung wird NetworkManager erneut auf laufende Arbeit geprüft.
# - Erfolg gilt erst mit Guest + connected + IPv4 + wpa_state=COMPLETED + echtem iw-Link.
# - Cooldowns nutzen monotone Bootzeit und bleiben von Uhrzeitsprüngen unbeeinflusst.
# - flock verhindert konkurrierende Reparaturläufe.

set -u
export LC_ALL=C
export LANG=C

PROFILE="Guest"
SSID="Guest"
TAG="uwuntu-wifi-selfheal"
LOG="/var/log/uwuntu-wifi-selfheal.log"
LOCK="/run/uwuntu-wifi-selfheal.lock"
PROFILE_OPTIMIZED_STAMP="/run/uwuntu-wifi-selfheal-profile-v1.3"
NOT_READY_STAMP="/run/uwuntu-wifi-selfheal-not-ready-v1.3"
RECREATE_STAMP="/run/uwuntu-wifi-selfheal-last-recreate-v1.3"
NM_RESTART_STAMP="/run/uwuntu-wifi-selfheal-last-nm-restart-v1.3"
AUTOCONNECT_GRACE_SECONDS=6
READY_STABLE_SECONDS=2
READY_WAIT_SECONDS=6

log() {
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S')  $*"
    echo "$msg" >> "$LOG" 2>/dev/null || true
    logger -t "$TAG" -- "$*" 2>/dev/null || true
}

nm() {
    nmcli "$@" 2>/dev/null
}

wifi_iface() {
    nm -t -f DEVICE,TYPE device status \
        | awk -F: '$2=="wifi" {print $1; exit}'
}

wifi_device_state() {
    local iface="$1"

    nm -t -f DEVICE,TYPE,STATE device status \
        | awk -F: -v dev="$iface" '$1==dev && $2=="wifi" {print $3; exit}'
}

guest_profile_uuids() {
    nm -t -f UUID,NAME,TYPE connection show \
        | awk -F: '$2=="Guest" && $3=="802-11-wireless" {print $1}'
}

guest_has_ipv4() {
    local iface="$1"

    nm -g IP4.ADDRESS device show "$iface" \
        | grep -Ev '^169\.254\.' \
        | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'
}

guest_wpa_completed() {
    local iface="$1"
    local status

    # wpa_cli ist auf den Uwuntu-Images vorhanden. Falls es auf einem anderen
    # System fehlt, bleibt iw als zweite echte Link-Prüfung bestehen.
    if ! command -v wpa_cli >/dev/null 2>&1; then
        return 0
    fi

    status="$(wpa_cli -i "$iface" status 2>/dev/null)" || return 1
    grep -Fxq 'wpa_state=COMPLETED' <<< "$status" \
        && grep -Fxq "ssid=$SSID" <<< "$status"
}

guest_iw_link_ok() {
    local iface="$1"
    local link

    if ! command -v iw >/dev/null 2>&1; then
        return 0
    fi

    link="$(iw dev "$iface" link 2>/dev/null)" || return 1
    grep -Eq '^Connected to [0-9a-fA-F:]{17} ' <<< "$link" \
        && grep -Eq "^[[:space:]]*SSID: ${SSID}$" <<< "$link"
}

guest_ready_now() {
    local iface="$1"

    nm -t -f DEVICE,TYPE,STATE,CONNECTION device status \
        | awk -F: -v dev="$iface" -v profile="$PROFILE" '
            $1==dev && $2=="wifi" && $3=="connected" && $4==profile {found=1}
            END {exit(found ? 0 : 1)}
        ' \
        || return 1

    guest_has_ipv4 "$iface" || return 1
    guest_wpa_completed "$iface" || return 1
    guest_iw_link_ok "$iface"
}

wait_guest_ready_stable() {
    local iface="$1"
    local deadline

    deadline=$((SECONDS + READY_WAIT_SECONDS))
    while (( SECONDS <= deadline )); do
        if guest_ready_now "$iface"; then
            sleep "$READY_STABLE_SECONDS"
            if guest_ready_now "$iface"; then
                return 0
            fi
        fi
        sleep 1
    done

    return 1
}

# Liefert 0, wenn NetworkManager das WLAN bereits selbst aufbaut oder gerade
# eine nominell verbundene, aber noch nicht vollständig bestätigte Verbindung
# hält. Dann darf Self-Heal keine zweite Aktivierung dazwischen schieben.
networkmanager_wifi_busy() {
    local iface="$1"
    local state

    state="$(wifi_device_state "$iface")"
    case "$state" in
        connecting*|connected*)
            return 0
            ;;
    esac
    return 1
}

# Diese Prüfung entscheidet ausschließlich über einen kompletten
# NetworkManager-Neustart. WLAN-Reparatur Stufe 1-3 läuft trotz LAN weiter.
other_network_connected() {
    nm -t -f TYPE,STATE device status \
        | awk -F: '
            $2=="connected" &&
            $1!="wifi" &&
            $1!="wifi-p2p" &&
            $1!="loopback" &&
            $1!="dummy" &&
            $1!="tun" &&
            $1!="bridge"
            {found=1}
            END {exit(found ? 0 : 1)}
        '
}

monotonic_seconds() {
    awk '{printf "%d\n", $1}' /proc/uptime 2>/dev/null || printf '0\n'
}

cooldown_ready() {
    local file="$1"
    local seconds="$2"
    local now last=0

    now="$(monotonic_seconds)"
    if [[ -r "$file" ]]; then
        read -r last < "$file" || last=0
    fi
    [[ "$now" =~ ^[0-9]+$ ]] || now=0
    [[ "$last" =~ ^[0-9]+$ ]] || last=0

    # Ein Wert aus einer anderen Boot-Sitzung kann größer als die aktuelle
    # monotone Uptime sein. Dann gilt der Cooldown bewusst als abgelaufen.
    (( last > now )) && return 0
    (( now - last >= seconds ))
}

mark_cooldown() {
    monotonic_seconds > "$1" 2>/dev/null || true
}

clear_not_ready_grace() {
    rm -f "$NOT_READY_STAMP" 2>/dev/null || true
}

autoconnect_grace_elapsed() {
    if [[ ! -r "$NOT_READY_STAMP" ]]; then
        mark_cooldown "$NOT_READY_STAMP"
        log "Guest noch nicht bereit. NetworkManager erhält zuerst ${AUTOCONNECT_GRACE_SECONDS}s für normalen Autoconnect."
        return 1
    fi

    cooldown_ready "$NOT_READY_STAMP" "$AUTOCONNECT_GRACE_SECONDS"
}

optimize_guest_profiles() {
    local uuid found=0 failed=0

    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] || continue
        found=1

        if ! nm connection modify uuid "$uuid" \
            connection.id "$PROFILE" \
            connection.interface-name "" \
            connection.autoconnect yes \
            connection.autoconnect-priority 100 \
            connection.autoconnect-retries 0 \
            802-11-wireless.ssid "$SSID" \
            802-11-wireless.mac-address "" \
            802-11-wireless.bssid "" \
            802-11-wireless.cloned-mac-address permanent \
            802-11-wireless.powersave 2 \
            ipv4.method auto \
            ipv6.method auto \
            >/dev/null 2>&1
        then
            failed=1
        fi
    done < <(guest_profile_uuids)

    [[ "$found" -eq 1 && "$failed" -eq 0 ]]
}

guest_visible() {
    local iface="$1"

    # Ein erzwungener Scan ist erst in Stufe 3 sinnvoll. Im normalen Boot und
    # in Stufe 1 darf er nicht mit einem laufenden wpa_supplicant-Scan kollidieren.
    nm device wifi rescan ifname "$iface" >/dev/null 2>&1 || true
    sleep 1

    nm -t -f SSID device wifi list ifname "$iface" \
        | grep -Fxq "$SSID"
}

# Rückgabewerte:
# 0 = Guest stabil bereit
# 1 = Verbindungsversuch ohne Erfolg
# 2 = NetworkManager arbeitet bereits; Self-Heal muss diesen Lauf beenden
try_guest_profiles() {
    local iface="$1"
    local uuid state

    # Schon vor Profiländerungen prüfen, ob NetworkManager inzwischen selbst
    # arbeitet. Eine aktive Association/Verbindung wird nicht angefasst.
    if guest_ready_now "$iface"; then
        clear_not_ready_grace
        return 0
    fi
    state="$(wifi_device_state "$iface")"
    if networkmanager_wifi_busy "$iface"; then
        log "NetworkManager arbeitet auf $iface bereits am WLAN-Zustand '$state'. Self-Heal wartet."
        return 2
    fi

    optimize_guest_profiles || true

    # Kein erzwungener Rescan hier: NetworkManager darf seinen laufenden Scan
    # und die normale Autoconnect-Logik unbehelligt abschließen.
    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] || continue

        # Kritische zweite Prüfung direkt vor nmcli connection up. Zwischen
        # Timer-Einstieg und diesem Punkt kann NetworkManager selbst mit Guest
        # begonnen haben. Eine zweite Aktivierung würde den laufenden Aufbau
        # sonst mit reason 'new-activation' wieder abreißen.
        if guest_ready_now "$iface"; then
            clear_not_ready_grace
            log "WLAN bereits stabil mit '$PROFILE' verbunden; keine erzwungene Aktivierung nötig."
            return 0
        fi

        state="$(wifi_device_state "$iface")"
        if networkmanager_wifi_busy "$iface"; then
            log "NetworkManager arbeitet auf $iface bereits am WLAN-Zustand '$state'. Erzwungene Guest-Aktivierung wird verschoben."
            return 2
        fi

        log "Versuche Guest-Profil UUID $uuid auf $iface."
        timeout 6s nmcli connection up uuid "$uuid" ifname "$iface" >/dev/null 2>&1 || true

        if wait_guest_ready_stable "$iface"; then
            clear_not_ready_grace
            log "WLAN stabil mit '$PROFILE' verbunden; IPv4, wpa_supplicant und iw-Link sind bestätigt."
            return 0
        fi
    done < <(guest_profile_uuids)

    return 1
}

delete_guest_profiles() {
    local uuid

    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] || continue
        log "Entferne defektes Guest-Profil UUID $uuid."
        nm connection delete uuid "$uuid" >/dev/null 2>&1 || true
    done < <(guest_profile_uuids)
}

# Rückgabewert 2 wird von try_guest_profiles durchgereicht.
recreate_guest_profile() {
    local iface="$1"
    local rc

    if ! guest_visible "$iface"; then
        log "SSID '$SSID' ist aktuell nicht sichtbar. Guest-Profil bleibt erhalten."
        return 1
    fi

    if ! cooldown_ready "$RECREATE_STAMP" 30; then
        log "Guest-Profil-Neuanlage im 30-Sekunden-Cooldown."
        return 1
    fi

    # Auch unmittelbar vor der destruktiven Neuanlage nochmals prüfen. Falls
    # NetworkManager inzwischen selbst verbindet, bleibt das Profil unangetastet.
    if guest_ready_now "$iface"; then
        clear_not_ready_grace
        return 0
    fi
    if networkmanager_wifi_busy "$iface"; then
        log "NetworkManager arbeitet auf $iface bereits am WLAN. Guest-Profil wird nicht neu angelegt."
        return 2
    fi

    mark_cooldown "$RECREATE_STAMP"
    log "SSID '$SSID' ist sichtbar. Erstelle Guest-Profil gezielt neu."
    delete_guest_profiles

    # Letzte Prüfung direkt vor der erzwungenen WLAN-Aktivierung.
    if networkmanager_wifi_busy "$iface"; then
        log "NetworkManager hat während der Profil-Neuanlage selbst begonnen. Erzwungene Aktivierung wird verschoben."
        return 2
    fi

    timeout 10s nmcli device wifi connect "$SSID" ifname "$iface" name "$PROFILE" >/dev/null 2>&1 || true
    if optimize_guest_profiles; then
        touch "$PROFILE_OPTIMIZED_STAMP" 2>/dev/null || true
    fi

    if wait_guest_ready_stable "$iface"; then
        clear_not_ready_grace
        log "Guest-Profil neu erstellt und stabil mit IPv4, wpa_supplicant und iw-Link verbunden."
        return 0
    fi

    try_guest_profiles "$iface"
    rc=$?
    return "$rc"
}

main() {
    local iface state rc

    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK"
        flock -n 9 || exit 0
    fi

    if ! command -v nmcli >/dev/null 2>&1; then
        log "ABBRUCH: nmcli nicht gefunden."
        exit 0
    fi

    if ! systemctl is-active --quiet NetworkManager.service; then
        for _ in 1 2 3 4 5; do
            sleep 1
            systemctl is-active --quiet NetworkManager.service && break
        done
    fi
    if ! systemctl is-active --quiet NetworkManager.service; then
        log "ABBRUCH: NetworkManager ist nicht aktiv."
        exit 0
    fi

    iface="$(wifi_iface)"
    if [[ -z "${iface:-}" ]]; then
        exit 0
    fi

    state="$(wifi_device_state "$iface")"

    # Während NetworkManager/wpa_supplicant das Gerät noch initialisiert oder
    # gerade verbindet, greift Self-Heal nicht ein. Damit funkt der Timer beim
    # Boot nicht mehr in prepare/config/ip-config/Scan/Association hinein.
    case "$state" in
        connecting*|unavailable*|unmanaged*|unknown*|"")
            exit 0
            ;;
    esac

    if guest_ready_now "$iface"; then
        clear_not_ready_grace

        # Profil nur einmal pro Boot normalisieren. Kein reapply: Eine bereits
        # stabile Verbindung wird durch Self-Heal nicht erneut angefasst.
        if [[ ! -e "$PROFILE_OPTIMIZED_STAMP" ]]; then
            if optimize_guest_profiles; then
                touch "$PROFILE_OPTIMIZED_STAMP" 2>/dev/null || true
            fi
        fi
        exit 0
    fi

    # Bei disconnected bzw. Guest ohne vollständig bestätigte Verbindung
    # bekommt NetworkManager zuerst selbst eine kurze Chance für Autoconnect,
    # DHCP und eventuelles Roaming.
    if ! autoconnect_grace_elapsed; then
        exit 0
    fi

    # Direkt nach der Schonfrist nochmals prüfen. Bei "connected", aber noch
    # nicht konsistentem wpa/iw-Zustand darf NetworkManager den Zustand zuerst
    # selbst bereinigen; der nächste Timerlauf schaut erneut nach.
    if networkmanager_wifi_busy "$iface"; then
        log "NetworkManager hält auf $iface bereits einen aktiven WLAN-Aufbau/Zustand. Self-Heal verschiebt den Eingriff auf den nächsten Timerlauf."
        exit 0
    fi

    log "Guest ist auf $iface nach Autoconnect-Schonfrist nicht bereit. Starte WLAN-Reparatur; LAN bleibt unangetastet."

    # Stufe 1: WLAN aktivieren/entsperren und Guest direkt verbinden.
    # Kein erzwungener WLAN-Scan in dieser Stufe.
    nm radio wifi on >/dev/null 2>&1 || true
    if command -v rfkill >/dev/null 2>&1; then
        rfkill unblock wifi >/dev/null 2>&1 || true
    fi
    sleep 1

    try_guest_profiles "$iface"
    rc=$?
    case "$rc" in
        0|2)
            exit 0
            ;;
    esac

    # Stufe 2: ausschließlich WLAN-Funkteil zurücksetzen. LAN läuft weiter.
    log "Stufe 1 ohne Erfolg. Setze ausschließlich WLAN-Funkteil zurück."
    nm radio wifi off >/dev/null 2>&1 || true
    sleep 1
    nm radio wifi on >/dev/null 2>&1 || true
    if command -v rfkill >/dev/null 2>&1; then
        rfkill unblock wifi >/dev/null 2>&1 || true
    fi
    sleep 2

    iface="$(wifi_iface)"
    if [[ -n "${iface:-}" ]]; then
        try_guest_profiles "$iface"
        rc=$?
        case "$rc" in
            0|2)
                exit 0
                ;;
        esac
    fi

    # Stufe 3: Nur wenn Guest sichtbar ist, ausschließlich Guest neu anlegen.
    if [[ -n "${iface:-}" ]]; then
        recreate_guest_profile "$iface"
        rc=$?
        case "$rc" in
            0|2)
                exit 0
                ;;
        esac
    fi

    # Stufe 4: kompletter NetworkManager-Neustart nur ohne LAN/WWAN/sonstige
    # echte Netzwerkverbindung. Bei aktivem LAN endet nur dieser Durchlauf;
    # der Timer versucht WLAN nach fünf Sekunden erneut.
    if other_network_connected; then
        log "Andere Netzwerkverbindung (z.B. LAN) aktiv. WLAN-Reparatur lief trotzdem; NetworkManager-Neustart wird übersprungen."
        exit 0
    fi

    if ! cooldown_ready "$NM_RESTART_STAMP" 60; then
        log "NetworkManager-Neustart im 60-Sekunden-Cooldown."
        exit 0
    fi

    mark_cooldown "$NM_RESTART_STAMP"
    log "Stufen 1-3 ohne Erfolg und keine andere Netzwerkverbindung aktiv. Starte NetworkManager einmal neu."
    systemctl restart NetworkManager.service >/dev/null 2>&1 || {
        log "FEHLER: NetworkManager konnte nicht neu gestartet werden."
        exit 0
    }

    sleep 2
    iface="$(wifi_iface)"
    if [[ -n "${iface:-}" ]]; then
        nm radio wifi on >/dev/null 2>&1 || true
        if command -v rfkill >/dev/null 2>&1; then
            rfkill unblock wifi >/dev/null 2>&1 || true
        fi

        try_guest_profiles "$iface"
        rc=$?
        case "$rc" in
            0)
                log "Guest nach NetworkManager-Neustart stabil mit IPv4, wpa_supplicant und iw-Link verbunden."
                exit 0
                ;;
            2)
                exit 0
                ;;
        esac
    fi

    log "Guest weiterhin nicht stabil bestätigt. Nächster Timer-Durchlauf versucht es erneut."
}

main "$@"
