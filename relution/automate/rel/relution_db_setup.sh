#!/usr/bin/env bash

# Installiert PostgreSQL nativ auf Debian als Datenbank für Relution.
# Legt Rolle und Datenbank an, öffnet
# den Zugriff ausschließlich für den Relution-App-Server und richtet einen
# nächtlichen pg_dump ein.
# Quelle(n):
#   https://hub.relution.io/en/docs/installation/requirements/
#   https://www.postgresql.org/docs/current/auth-pg-hba-conf.html
#   https://wiki.debian.org/PostgreSql
# Mit Statusanzeige und Fehlerprüfung nach jedem Schritt.
# Getestet: bash -n, shellcheck, Teillogik mit Fake-Eingaben – nicht auf einem Zielsystem ausgeführt.

# shellcheck disable=SC2329  # Hilfsfunktionen werden indirekt über run() aufgerufen
set -uo pipefail   # bewusst ohne -e: Fehler werden explizit über run()/fail() behandelt

# ================= VOR DEM START ANPASSEN =================
APP_IP="<APP-IP>"          # IP des Relution-App-Servers (einziger erlaubter Client)
DB_LISTEN_IP="<DB-IP>"     # eigene IP dieses Servers, auf der PostgreSQL lauscht
DB_NAME="relution"
DB_USER="relution"
DB_PASSWORD=""             # leer = wird erzeugt, gespeichert und am Ende angezeigt
# ==========================================================

# ---------- Farben / Formatierung ----------
# Farben nur im Terminal und wenn NO_COLOR nicht gesetzt ist
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly C_RESET='\033[0m'  C_BOLD='\033[1m'
    readonly C_GREEN='\033[0;32m' C_RED='\033[0;31m'
    readonly C_YELLOW='\033[0;33m' C_BLUE='\033[0;34m'
else
    readonly C_RESET='' C_BOLD='' C_GREEN='' C_RED='' C_YELLOW='' C_BLUE=''
fi

SCRIPT_NAME="$(basename "$0" .sh)"
readonly SCRIPT_NAME
readonly LOG_FILE="/tmp/${SCRIPT_NAME}.log"
: > "$LOG_FILE"
chmod 600 "$LOG_FILE"

readonly CRED_FILE="/root/relution-db-credentials.txt"
readonly BACKUP_DIR="/var/backups/pg"

STEP_NUM=0
TOTAL_STEPS=8   # bei jedem neuen log_step anpassen!

# ---------- Ausgabe-Funktionen ----------
log_step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo -e "\n${C_BOLD}${C_BLUE}[${STEP_NUM}/${TOTAL_STEPS}]${C_RESET} ${C_BOLD}$1${C_RESET}"
}

log_ok()   { echo -e "  ${C_GREEN}✔${C_RESET} $1"; }
log_err()  { echo -e "  ${C_RED}✘${C_RESET} $1"; }
log_warn() { echo -e "  ${C_YELLOW}⚠${C_RESET} $1"; }

fail() {
    echo -e "\n  ${C_RED}✘ ${C_BOLD}Vorgang abgebrochen.${C_RESET}"
    echo -e "  ${C_BOLD}Grund:${C_RESET} $1"
    echo -e "  ${C_BOLD}Log:${C_RESET}   ${LOG_FILE}"
    exit 1
}

# Abbruch per Strg+C oder kill ebenfalls mit Grund melden
trap 'echo; fail "Abbruch durch Benutzer oder Signal (Strg+C/kill) in Schritt ${STEP_NUM}/${TOTAL_STEPS}."' INT TERM


# Führt einen Befehl aus, hängt die Ausgabe ans Log an und bricht bei Fehler ab
run() {
    local desc="$1"
    shift
    echo "### $desc: $*" >>"$LOG_FILE"
    if "$@" >>"$LOG_FILE" 2>&1; then
        log_ok "$desc"
    else
        log_err "$desc"
        echo -e "${C_YELLOW}  --- Letzte Log-Zeilen ---${C_RESET}"
        tail -n 15 "$LOG_FILE" | sed 's/^/    /'
        fail "Schritt '${desc}' fehlgeschlagen (Befehl: $*). Details im Log-Auszug oben."
    fi
}

# Ja/Nein-Abfrage; ohne Terminal (z.B. curl | bash) gilt der Default
confirm() {
    local prompt="$1" default="${2:-n}" answer
    if [[ -t 0 ]]; then
        read -r -p "  ${prompt} [y/N] " answer
    else
        answer="$default"
        log_warn "Keine interaktive Eingabe möglich — verwende Standard: ${default}"
    fi
    [[ "$answer" =~ ^[yY]$ ]]
}

# ---------- Hilfsfunktionen ----------
# Bricht ab, wenn eine Variable leer ist oder noch einen <PLATZHALTER> enthält
require_vars() {
    local name
    for name in "$@"; do
        [[ -n "${!name}" && "${!name}" != *"<"* ]] \
            || fail "Variable ${name} ist nicht gesetzt (Block 'VOR DEM START ANPASSEN' oben im Skript)."
    done
}

gen_secret() {   # alphanumerisch, Länge $1 – unkritisch für Shell, SQL und YAML
    local s
    s="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$1")"
    printf '%s' "$s"
}

# psql als Benutzer postgres (root: runuser, sonst sudo)
pg_exec() {
    if [[ -z "$SUDO" ]]; then
        runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 "$@"
    else
        sudo -u postgres psql -X -v ON_ERROR_STOP=1 "$@"
    fi
}

# Rolle anlegen bzw. Passwort setzen – SQL über stdin, damit das Passwort nicht im Log landet
apply_role() {
    if [[ "$(pg_exec -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'")" == "1" ]]; then
        printf "ALTER ROLE \"%s\" WITH LOGIN PASSWORD '%s';\n" "$DB_USER" "$DB_PASSWORD" | pg_exec
    else
        printf "CREATE ROLE \"%s\" WITH LOGIN PASSWORD '%s';\n" "$DB_USER" "$DB_PASSWORD" | pg_exec
    fi
}

create_db() {
    if [[ "$(pg_exec -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")" == "1" ]]; then
        echo "Datenbank ${DB_NAME} existiert bereits."
    else
        pg_exec -c "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\" ENCODING 'UTF8' TEMPLATE template0;"
    fi
}

save_credentials() {
    local tmp
    tmp="$(mktemp)"
    printf 'DB_HOST=%s\nDB_NAME=%s\nDB_USER=%s\nDB_PASSWORD=%s\n' \
        "$DB_LISTEN_IP" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" > "$tmp"
    $SUDO install -m 0600 -o root -g root "$tmp" "$CRED_FILE"
    rm -f "$tmp"
}

append_hba() {
    printf '%s\n' "$HBA_LINE" | $SUDO tee -a "$HBA_FILE" >/dev/null
}

# ---------- Vorprüfungen ----------
echo -e "${C_BOLD}Relution – PostgreSQL-Server einrichten${C_RESET}"

# Root/sudo
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    command -v sudo &>/dev/null \
        || fail "Root-Rechte erforderlich, sudo ist nicht installiert (typisch für Debian-Minimal). Als root anmelden mit 'su -' (mit Bindestrich) und Skript erneut starten – sudo wird dabei mitinstalliert."
    SUDO="sudo"
fi

# Betriebssystem
[[ -f /etc/os-release ]] || fail "/etc/os-release nicht gefunden."
# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "debian" && "${ID_LIKE:-}" != *debian* ]]; then
    fail "Nur für Debian/Derivate gedacht (erkannt: ${PRETTY_NAME:-${ID:-unbekannt}})."
fi
log_ok "System erkannt: ${PRETTY_NAME:-${ID:-unbekannt}}"

require_vars APP_IP DB_LISTEN_IP DB_NAME DB_USER
hostname -I | tr ' ' '\n' | grep -qx "${DB_LISTEN_IP}" \
    || fail "DB_LISTEN_IP ${DB_LISTEN_IP} ist auf diesem Server nicht konfiguriert ('hostname -I' prüfen)."
log_ok "Konfiguration: Zugriff nur von ${APP_IP}, Lauschadresse ${DB_LISTEN_IP}"

# Bereits erledigt? (Idempotenz)
if dpkg-query -W -f='${db:Status-Status}' postgresql 2>/dev/null | grep -q '^installed$'; then
    log_warn "PostgreSQL ist bereits installiert – Konfiguration wird geprüft und ergänzt."
    confirm "Trotzdem fortfahren?" y || { echo "Abgebrochen."; exit 0; }
fi

# ---------- Schritt 1: Pakete installieren ----------
log_step "Pakete installieren (Basiswerkzeuge, PostgreSQL)"

run "Paketlisten aktualisiert (bei Fehler: Repo-/Proxy-Einstellung für apt prüfen)" $SUDO apt-get update
run "Pakete installiert" $SUDO env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y sudo iproute2 procps ca-certificates curl gnupg chrony cron bind9-dnsutils netcat-openbsd less postgresql

# ---------- Schritt 2: Zeit synchronisieren ----------
log_step "Zeitzone und Zeitsynchronisation"

run "Zeitzone Europe/Berlin" $SUDO timedatectl set-timezone Europe/Berlin
run "chrony aktiviert" $SUDO systemctl enable --now chrony

# ---------- Schritt 3: Cluster ermitteln ----------
log_step "PostgreSQL-Cluster ermitteln"

PG_VER="$(find /etc/postgresql -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n 1)"
[[ -n "$PG_VER" ]] || fail "Kein Cluster unter /etc/postgresql gefunden ('pg_lsclusters' prüfen)."
readonly CONF_DIR="/etc/postgresql/${PG_VER}/main"
readonly HBA_FILE="${CONF_DIR}/pg_hba.conf"
[[ -f "$HBA_FILE" ]] || fail "${HBA_FILE} nicht gefunden."
(( ${PG_VER%%.*} >= 14 )) || fail "PostgreSQL ${PG_VER} ist zu alt – Relution verlangt mindestens 14."
log_ok "PostgreSQL ${PG_VER}, Konfiguration in ${CONF_DIR}"

if systemctl is-active --quiet postgresql; then
    log_ok "Dienst postgresql läuft"
else
    run "Dienst postgresql gestartet" $SUDO systemctl enable --now postgresql
fi

# ---------- Schritt 4: Rolle und Datenbank ----------
log_step "Rolle und Datenbank für Relution"

if [[ -z "$DB_PASSWORD" ]] && $SUDO test -f "$CRED_FILE"; then
    DB_PASSWORD="$($SUDO grep '^DB_PASSWORD=' "$CRED_FILE" | cut -d= -f2-)"
    log_ok "Vorhandenes Passwort aus ${CRED_FILE} übernommen"
fi
if [[ -z "$DB_PASSWORD" ]]; then
    DB_PASSWORD="$(gen_secret 40)"
    log_ok "Neues Datenbank-Passwort erzeugt (40 Zeichen)"
fi
[[ "$DB_PASSWORD" =~ ^[A-Za-z0-9._-]+$ ]] \
    || fail "DB_PASSWORD darf nur A-Z, a-z, 0-9, . _ - enthalten (vermeidet Quoting-Probleme)."

run "Rolle ${DB_USER} angelegt/aktualisiert" apply_role
run "Datenbank ${DB_NAME} vorhanden" create_db
run "Zugangsdaten gespeichert (${CRED_FILE}, nur root)" save_credentials

# ---------- Schritt 5: Netzwerkzugriff ----------
log_step "Netzwerkzugriff nur für den App-Server"

$SUDO grep -Eq "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf\.d'" "${CONF_DIR}/postgresql.conf" \
    || fail "include_dir 'conf.d' fehlt in postgresql.conf – listen_addresses manuell setzen."

TMP_FILE="$(mktemp)"
cat > "$TMP_FILE" <<EOF
# Relution – verwaltet durch ${SCRIPT_NAME}.sh
listen_addresses = 'localhost,${DB_LISTEN_IP}'
password_encryption = 'scram-sha-256'
EOF
run "listen_addresses gesetzt (conf.d/relution.conf)" \
    $SUDO install -m 0644 -o postgres -g postgres "$TMP_FILE" "${CONF_DIR}/conf.d/relution.conf"
rm -f "$TMP_FILE"

HBA_LINE="host    ${DB_NAME}    ${DB_USER}    ${APP_IP}/32    scram-sha-256"
if $SUDO grep -qF "$HBA_LINE" "$HBA_FILE"; then
    log_ok "pg_hba.conf enthält den Eintrag bereits"
else
    run "pg_hba.conf: Zugriff nur von ${APP_IP}" append_hba
fi

# ---------- Schritt 6: Neustart und Prüfung ----------
log_step "PostgreSQL neu starten und prüfen"

run "PostgreSQL neu gestartet" $SUDO systemctl restart postgresql
sleep 2
if ss -tln | grep -q "${DB_LISTEN_IP}:5432"; then
    log_ok "PostgreSQL lauscht auf ${DB_LISTEN_IP}:5432"
else
    fail "PostgreSQL lauscht nicht auf ${DB_LISTEN_IP}:5432 – 'journalctl -u postgresql@${PG_VER}-main' prüfen."
fi

if command -v nft &>/dev/null && $SUDO nft list ruleset 2>/dev/null | grep -q 'hook input'; then
    log_warn "Lokale nftables-Regeln aktiv – sicherstellen, dass 5432 von ${APP_IP} erlaubt ist."
fi

# ---------- Schritt 7: Backup ----------
log_step "Nächtlicher pg_dump"

run "Backup-Verzeichnis ${BACKUP_DIR}" $SUDO install -d -m 0750 -o postgres -g postgres "$BACKUP_DIR"
TMP_FILE="$(mktemp)"
cat > "$TMP_FILE" <<EOF
# Relution – täglicher Dump, 14 Tage Aufbewahrung
30 2 * * * postgres pg_dump -Fc ${DB_NAME} > ${BACKUP_DIR}/${DB_NAME}_\$(date +\%F).dump && find ${BACKUP_DIR} -name '*.dump' -mtime +14 -delete
EOF
run "Cronjob /etc/cron.d/relution-pgdump" $SUDO install -m 0644 "$TMP_FILE" /etc/cron.d/relution-pgdump
rm -f "$TMP_FILE"

# ---------- Schritt 8: Zusammenfassung ----------
log_step "Zusammenfassung"

log_ok "PostgreSQL ${PG_VER} – Datenbank ${DB_NAME}, Benutzer ${DB_USER}"
log_ok "Erreichbar: ${DB_LISTEN_IP}:5432, nur von ${APP_IP}"
log_ok "Backup: täglich 02:30 nach ${BACKUP_DIR}"
log_warn "sudo ist installiert – Admin-Benutzer bei Bedarf berechtigen: usermod -aG sudo <benutzer>"
echo
echo -e "  ${C_BOLD}Für das App-Server-Skript übernehmen:${C_RESET}"
echo "    DB_HOST=\"${DB_LISTEN_IP}\""
echo "    DB_PASSWORD=\"${DB_PASSWORD}\""
log_warn "Passwort liegt auch in ${CRED_FILE} – nicht in Tickets/Chats kopieren."
log_warn "Verbindungstest vom App-Server: psql \"host=${DB_LISTEN_IP} user=${DB_USER} dbname=${DB_NAME}\" -c 'SELECT 1;'"
echo -e "\n${C_GREEN}${C_BOLD}PostgreSQL-Einrichtung erfolgreich abgeschlossen!${C_RESET}"

exit 0
