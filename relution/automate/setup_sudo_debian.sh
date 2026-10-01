#!/usr/bin/env bash

# Installiert sudo auf Debian (inkl. Derivate) nach und fügt nach Rückfrage
# einen Benutzer zur Gruppe "sudo" hinzu.
# Mit Statusanzeige, Logging und Fehlerprüfung.
# Benötigt root-Rechte oder sudo.

set -uo pipefail

# ---------- Farben / Formatierung ----------
readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_GREEN='\033[0;32m'
readonly C_RED='\033[0;31m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'

readonly LOG_FILE="/tmp/setup-sudo.log"
: > "$LOG_FILE"

STEP_NUM=0
TOTAL_STEPS=4

log_step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo -e "\n${C_BOLD}${C_BLUE}[${STEP_NUM}/${TOTAL_STEPS}]${C_RESET} ${C_BOLD}$1${C_RESET}"
}

log_ok()   { echo -e "  ${C_GREEN}✔${C_RESET} $1"; }
log_err()  { echo -e "  ${C_RED}✘${C_RESET} $1"; }
log_warn() { echo -e "  ${C_YELLOW}⚠${C_RESET} $1"; }

fail() {
    log_err "$1"
    echo -e "\n${C_RED}${C_BOLD}Abgebrochen.${C_RESET} Log: ${LOG_FILE}"
    exit 1
}

# Führt einen Befehl aus und prüft den Exit-Code (Log wird angehängt, nicht überschrieben)
run() {
    local desc="$1"
    shift
    echo "### $desc: $*" >>"$LOG_FILE"
    if "$@" >>"$LOG_FILE" 2>&1; then
        log_ok "$desc"
        return 0
    else
        log_err "$desc"
        echo -e "${C_YELLOW}  --- Letzte Log-Zeilen ---${C_RESET}"
        tail -n 15 "$LOG_FILE" | sed 's/^/    /'
        fail "Befehl fehlgeschlagen: $*"
    fi
}

echo -e "${C_BOLD}sudo-Setup für Debian${C_RESET}"

# ---------- Schritt 1: Rechte prüfen ----------
log_step "Rechte prüfen"

if [[ $EUID -ne 0 ]]; then
    fail "Dieses Skript muss als root ausgeführt werden (z.B. 'su -', dann ./setup-sudo.sh)."
fi
# PATH ergänzen: bei "su" ohne "-" fehlen /usr/sbin und /sbin,
# dort liegen usermod, apt-get, groupadd usw.
export PATH="/usr/local/sbin:/usr/sbin:/sbin:${PATH}"
log_ok "Als root gestartet, PATH ergänzt"

# ---------- Schritt 2: sudo bereitstellen ----------
log_step "sudo bereitstellen"

if command -v sudo >/dev/null 2>&1; then
    log_ok "sudo bereits installiert ($(sudo --version 2>/dev/null | head -n1))"
else
    log_warn "sudo nicht gefunden — wird installiert"
    export DEBIAN_FRONTEND=noninteractive
    run "apt update" apt-get update
    run "sudo installiert" apt-get install -y sudo
fi

# ---------- Schritt 3: Benutzer zur sudo-Gruppe hinzufügen ----------
log_step "Benutzer zur sudo-Gruppe hinzufügen"

if [[ -t 0 ]]; then
    read -r -p "  Benutzer zur sudo-Gruppe hinzufügen? [j/N] " antwort
else
    antwort="n"
    log_warn "Keine interaktive Eingabe möglich — überspringe"
fi

ADDED_USER=""
case "$antwort" in
    [jJyY])
        read -r -p "  Benutzername: " benutzer

        if [[ -z "$benutzer" ]]; then
            fail "Kein Benutzername eingegeben."
        fi
        if ! id "$benutzer" >/dev/null 2>&1; then
            fail "Benutzer '$benutzer' existiert nicht."
        fi

        if id -nG "$benutzer" | tr ' ' '\n' | grep -qx "sudo"; then
            log_ok "Benutzer '$benutzer' ist bereits in der Gruppe sudo"
        else
            run "Benutzer '$benutzer' zur Gruppe sudo hinzugefügt" usermod -aG sudo "$benutzer"
            log_warn "'$benutzer' muss sich neu anmelden, damit die Gruppe greift"
        fi
        ADDED_USER="$benutzer"
        ;;
    *)
        log_warn "Kein Benutzer hinzugefügt"
        ;;
esac

# ---------- Schritt 4: Zusammenfassung ----------
log_step "Zusammenfassung"

log_ok "sudo: $(sudo --version 2>/dev/null | head -n1 || echo 'unbekannt')"
if [[ -n "$ADDED_USER" ]]; then
    log_ok "Gruppe sudo: $(id -nG "$ADDED_USER" 2>/dev/null | tr ' ' '\n' | grep -qx sudo && echo "'$ADDED_USER' ist Mitglied")"
else
    log_ok "Kein Benutzer geändert"
fi

echo -e "\n${C_GREEN}${C_BOLD}Fertig.${C_RESET} Log: ${LOG_FILE}"
exit 0
