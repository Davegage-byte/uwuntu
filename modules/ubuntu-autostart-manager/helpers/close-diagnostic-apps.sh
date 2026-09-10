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
