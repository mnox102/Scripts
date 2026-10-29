#!/usr/bin/env bash

# Lokales Backup von grafana-mdm (Grafana nativ als Paket installiert, kein Docker):
# Grafana (SQLite-DB als konsistente Kopie, /etc/grafana, /var/lib/grafana), Caddy,
# WireGuard-Hub (/etc/wireguard) und Doku-Berichte der vServer.
# Ablage: /backup/<NAME>-server_<DATUM>_<UHRZEIT>.tar.gz (+ .sha256), Log: /var/log/<NAME>-backup.log
# Rotation nach KEEP_DAYS Tagen.
# Ein Sync zu Strato HiDrive ist vorbereitet (auskommentiert, Schritt 6).
#
# Quelle(n):
#   https://grafana.com/docs/grafana/latest/administration/back-up-grafana/
#   https://www.sqlite.org/cli.html  (.backup = konsistente Online-Kopie)
# Mit Statusanzeige und Fehlerprüfung nach jedem Schritt.
#
# Läuft als root. Empfohlener Turnus: täglich nachts, z.B. /etc/cron.d/grafana-backup:
#   30 1 * * * root /usr/local/var/grafana-backup.sh >> /var/log/grafana-backup.err.log 2>&1
# Zusätzlich manuell vor jedem Grafana-/Caddy-Upgrade (apt upgrade) ausführen.
#
# Einstellungen können in /etc/backup/grafana-backup.conf überschrieben werden.
#
# ACHTUNG: Das Archiv enthält private WireGuard-Schlüssel. Verzeichnis ist 0700,
# Archive 0600. Vor einem externen Sync verschlüsseln (siehe Schritt 6).
#
# Getestet: bash -n, shellcheck. Nicht auf grafana-mdm selbst getestet.

set -uo pipefail   # bewusst ohne -e: Fehler werden explizit über run()/fail() behandelt

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
readonly LOG_FILE="/var/log/grafana-backup.log"   # wird angehängt, nie überschrieben
readonly CONF_FILE="/etc/backup/grafana-backup.conf"

# ---------- Einstellungen (Defaults, per CONF_FILE überschreibbar) ----------
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
fi

GRAFANA_CONF_DIR="${GRAFANA_CONF_DIR:-/etc/grafana}"
GRAFANA_DATA="${GRAFANA_DATA:-/var/lib/grafana}"
GRAFANA_DB="${GRAFANA_DB:-${GRAFANA_DATA}/grafana.db}"
DOKU_DIR="${DOKU_DIR:-/srv/serverdoku}"          # Push-Ziel der vServer-Doku, falls vorhanden
BACKUP_DIR="${BACKUP_DIR:-/backup}"
KEEP_DAYS="${KEEP_DAYS:-14}"
MIN_FREE_MB="${MIN_FREE_MB:-2048}"

BACKUP_NAME="${BACKUP_NAME:-grafana-server}"   # Dateiname: <NAME>_<DATUM>.tar.gz
TIMESTAMP="$(date +%F_%H%M)"
ARCHIVE="${BACKUP_DIR}/${BACKUP_NAME}_${TIMESTAMP}.tar.gz"
STAGING=""

STEP_NUM=0
TOTAL_STEPS=7   # bei jedem neuen log_step anpassen!

# ---------- Ausgabe-Funktionen ----------
log_step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo -e "\n${C_BOLD}${C_BLUE}[${STEP_NUM}/${TOTAL_STEPS}]${C_RESET} ${C_BOLD}$1${C_RESET}"
}

log_ok()   { echo -e "  ${C_GREEN}✔${C_RESET} $1"; }
log_err()  { echo -e "  ${C_RED}✘${C_RESET} $1"; }
log_warn() { echo -e "  ${C_YELLOW}⚠${C_RESET} $1"; }

fail() {
    log_err "$1"
    echo "===== $(date '+%F %T') Ende FEHLER: $1 =====" >>"$LOG_FILE"
    echo -e "\n${C_RED}${C_BOLD}Backup abgebrochen.${C_RESET} Log: ${LOG_FILE}"
    rm -f "$ARCHIVE" "${ARCHIVE}.sha256" 2>/dev/null
    exit 1
}

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
        fail "Befehl fehlgeschlagen: $*"
    fi
}

# shellcheck disable=SC2329  # wird über trap aufgerufen
cleanup() {
    if [[ -n "$STAGING" && -d "$STAGING" ]]; then
        rm -rf "$STAGING"
    fi
}
trap cleanup EXIT

# tar mit Toleranz für Dateien, die sich während des Lesens ändern (Exit 1 bei GNU tar,
# z.B. laufende Logs). Exit 2 = echter Fehler.
# shellcheck disable=SC2329  # wird über run() aufgerufen
tar_create() {
    local rc
    tar --create --gzip --warning=no-file-changed "$@"
    rc=$?
    [[ $rc -le 1 ]]
}

# Pfade für tar sammeln (relativ zu /), nur wenn vorhanden und nicht schon abgedeckt
TAR_PATHS=()
add_path() {
    local p="${1%/}" existing
    if [[ ! -e "$p" ]]; then
        log_warn "Nicht vorhanden, übersprungen: $p"
        return 0
    fi
    for existing in "${TAR_PATHS[@]}"; do
        [[ "${p#/}/" == "${existing}/"* ]] && return 0
    done
    TAR_PATHS+=("${p#/}")
    log_ok "Wird gesichert: $p"
}

# ---------- Vorprüfungen ----------
echo -e "${C_BOLD}Backup grafana-mdm${C_RESET}"

[[ $EUID -eq 0 ]] || { echo "Muss als root laufen (Cron/systemd-Timer oder sudo)."; exit 1; }
echo "===== $(date '+%F %T') Start ${SCRIPT_NAME} =====" >>"$LOG_FILE"

for cmd in sqlite3 tar gzip sha256sum flock; do
    command -v "$cmd" &>/dev/null || fail "'$cmd' fehlt. Installieren, z.B.: apt install ${cmd}"
done

[[ -f "$GRAFANA_DB" ]] || fail "Grafana-DB nicht gefunden: $GRAFANA_DB (GRAFANA_DB in $CONF_FILE setzen)"
# Nur SQLite wird unterstützt – bei MySQL/PostgreSQL ist ein Dump nötig
if grep -Eiq '^[[:space:]]*type[[:space:]]*=[[:space:]]*(mysql|postgres)' "${GRAFANA_CONF_DIR}/grafana.ini" 2>/dev/null; then
    fail "Grafana nutzt laut grafana.ini MySQL/PostgreSQL – dieses Skript sichert nur SQLite."
fi
if systemctl is-active --quiet grafana-server; then
    log_ok "grafana-server aktiv"
else
    log_warn "grafana-server läuft nicht – Backup wird trotzdem erstellt."
fi

# Parallele Läufe verhindern
exec 9>"/run/lock/${SCRIPT_NAME}.lock"
flock -n 9 || fail "Es läuft bereits ein Backup (Lock: /run/lock/${SCRIPT_NAME}.lock)."

install -d -m 0700 "$BACKUP_DIR" || fail "Backup-Verzeichnis nicht anlegbar: $BACKUP_DIR"
FREE_MB=$(df -Pm "$BACKUP_DIR" | awk 'NR==2 {print $4}')
(( FREE_MB >= MIN_FREE_MB )) || fail "Zu wenig Platz in $BACKUP_DIR: ${FREE_MB} MB frei, mindestens ${MIN_FREE_MB} MB nötig."
log_ok "Freier Platz in ${BACKUP_DIR}: ${FREE_MB} MB"

STAGING="$(mktemp -d "${BACKUP_DIR}/.staging.XXXXXX")" || fail "Staging-Verzeichnis nicht anlegbar."

# ---------- Schritt 1: Quellen ermitteln ----------
log_step "Quellen ermitteln"

# Grafana
add_path "$GRAFANA_CONF_DIR"
add_path /etc/default/grafana-server
add_path "$GRAFANA_DATA"            # Plugins, Provisioning-Daten; Live-DB wird beim Packen ausgeschlossen

# WireGuard-Hub
add_path /etc/wireguard

# Caddy (Paket-Installation: Config in /etc/caddy, Zertifikate/interne CA in /var/lib/caddy)
add_path /etc/caddy
add_path /var/lib/caddy

# Push-Ziel der vServer-Doku
add_path "$DOKU_DIR"

# Systeminfo für den Restore (OS, IP, Paketversionen – beim Restore gleiche Version installieren)
{
    cat /etc/os-release
    echo; echo "Host: $(hostname -f) / $(hostname -I)"
    echo; dpkg-query -W -f='${Package} ${Version}
' grafana grafana-enterprise caddy wireguard-tools 2>/dev/null
} > "${STAGING}/host-info.txt"
log_ok "Systeminfo und Paketversionen erfasst"

# ---------- Schritt 2: Grafana-Datenbank konsistent sichern ----------
log_step "Grafana-Datenbank konsistent sichern"

run "SQLite-Online-Backup" sqlite3 "$GRAFANA_DB" ".backup '${STAGING}/grafana-db-backup.sqlite'"

CHECK="$(sqlite3 "${STAGING}/grafana-db-backup.sqlite" 'PRAGMA integrity_check;' 2>>"$LOG_FILE")"
[[ "$CHECK" == "ok" ]] || fail "Integritätsprüfung der DB-Kopie fehlgeschlagen: $CHECK"
log_ok "Integritätsprüfung der DB-Kopie: ok"

# ---------- Schritt 3: Archiv erstellen ----------
log_step "Archiv erstellen"

# Live-DB wird ausgeschlossen, die konsistente Kopie liegt im Staging
run "Archiv geschrieben: $(basename "$ARCHIVE")" \
    tar_create --file "$ARCHIVE" \
        --exclude="$(basename "$GRAFANA_DB")" --exclude="$(basename "$GRAFANA_DB")-*" \
        -C / "${TAR_PATHS[@]}" \
        -C "$STAGING" .
chmod 0600 "$ARCHIVE"

# ---------- Schritt 4: Archiv prüfen ----------
log_step "Archiv prüfen"

run "Archiv lesbar (gzip -t)" gzip -t "$ARCHIVE"
# Inhaltsliste erst in eine Datei schreiben: "tar | grep -q" bricht tar per SIGPIPE ab,
# mit pipefail wäre die Prüfung dann fälschlich negativ.
ARCHIVE_LIST="${STAGING}/archive-list.txt"
tar -tzf "$ARCHIVE" > "$ARCHIVE_LIST" 2>>"$LOG_FILE" || fail "Inhaltsliste des Archivs konnte nicht gelesen werden."
if grep -q 'grafana-db-backup\.sqlite$' "$ARCHIVE_LIST"; then
    log_ok "DB-Kopie im Archiv enthalten"
else
    fail "DB-Kopie fehlt im Archiv."
fi
( cd "$BACKUP_DIR" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" ) \
    || fail "Prüfsumme konnte nicht geschrieben werden."
chmod 0600 "${ARCHIVE}.sha256"
log_ok "SHA256-Prüfsumme geschrieben"

# ---------- Schritt 5: Alte Backups rotieren ----------
log_step "Alte Backups rotieren (älter als ${KEEP_DAYS} Tage)"

DELETED=$(find "$BACKUP_DIR" -maxdepth 1 -type f \
    \( -name "${BACKUP_NAME}_*.tar.gz" -o -name "${BACKUP_NAME}_*.tar.gz.sha256" -o -name "${BACKUP_NAME}_*.tar.gz.age" \) \
    -mtime +"$KEEP_DAYS" -print -delete | wc -l)
log_ok "${DELETED} alte Datei(en) gelöscht"

# ---------- Schritt 6: Sync zu Strato (vorbereitet) ----------
log_step "Sync zu Strato HiDrive"

log_warn "Noch nicht aktiv – Backup liegt nur lokal auf diesem Server."
# Vorbereitung (einmalig):
#   1. SSH-Key erzeugen:  ssh-keygen -t ed25519 -f /root/.ssh/hidrive_backup -N ""
#   2. Public Key im HiDrive-Konto hinterlegen, Zielordner anlegen, Zugang einmal testen.
#   3. age installieren (apt install age), Schlüsselpaar mit age-keygen erzeugen.
#      Nur den Public Key hier eintragen, den Private Key NICHT auf diesem Server lassen
#      (KeePass/Vaultwarden) – sonst ist er beim Serververlust mit weg.
#
# AGE_RECIPIENT="${AGE_RECIPIENT:-age1...}"
# STRATO_USER="${STRATO_USER:-<hidrive-benutzer>}"
# STRATO_TARGET="${STRATO_USER}@rsync.hidrive.strato.com:/users/${STRATO_USER}/backups/grafana-mdm/"
#
# run "Archiv verschlüsselt (age)" age -r "$AGE_RECIPIENT" -o "${ARCHIVE}.age" "$ARCHIVE"
# chmod 0600 "${ARCHIVE}.age"
# run "Sync zu Strato HiDrive" \
#     rsync -a --partial \
#         -e "ssh -i /root/.ssh/hidrive_backup -o BatchMode=yes" \
#         --include="${BACKUP_NAME}_*.tar.gz.age" --include="${BACKUP_NAME}_*.tar.gz.sha256" --exclude='*' \
#         "${BACKUP_DIR}/" "$STRATO_TARGET"
#
# Hinweis: bewusst ohne --delete, damit lokal rotierte Backups remote erhalten bleiben.
# Die Aufbewahrung auf HiDrive (z.B. 6 Monate) separat regeln.

# ---------- Schritt 7: Zusammenfassung ----------
log_step "Zusammenfassung"

SIZE="$(du -h "$ARCHIVE" | cut -f1)"
COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -name "${BACKUP_NAME}_*.tar.gz" | wc -l)
log_ok "Archiv: ${ARCHIVE} (${SIZE})"
log_ok "Vorhandene Backups: ${COUNT} (Aufbewahrung ${KEEP_DAYS} Tage)"
log_warn "Nur lokale Kopie – schützt nicht vor Platten- oder Serververlust."
echo "===== $(date '+%F %T') Ende OK =====" >>"$LOG_FILE"
echo -e "\n${C_GREEN}${C_BOLD}Backup erfolgreich abgeschlossen!${C_RESET}"

exit 0
