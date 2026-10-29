#!/usr/bin/env bash

# Lokales Backup von wazuh-mdm (Wazuh All-in-One, Paket-Installation):
# Agent-Schlüssel, Zertifikate, Manager-/Indexer-/Dashboard-Konfiguration,
# Agent-Datenbanken (kurzer Manager-Stopp) und Logs.
# Optional: Snapshot des Wazuh-Indexers (vorab path.repo + Repository einrichten).
# Ablage: /backup/<NAME>-server_<DATUM>_<UHRZEIT>.tar.gz (+ .sha256), Log: /var/log/<NAME>-backup.log
# Rotation nach KEEP_DAYS Tagen.
# Ein Sync zu Strato HiDrive ist vorbereitet (auskommentiert, Schritt 7).
#
# Quelle(n):
#   https://documentation.wazuh.com/current/migration-guide/creating/wazuh-central-components.html
#   https://documentation.wazuh.com/current/user-manual/wazuh-indexer/migrating-wazuh-indices.html
# Mit Statusanzeige und Fehlerprüfung nach jedem Schritt.
#
# Läuft als root. Empfohlener Turnus: täglich nachts, versetzt zum Grafana-Backup,
# z.B. /etc/cron.d/wazuh-backup:
#   0 2 * * * root /usr/local/var/wazuh-backup.sh >> /var/log/wazuh-backup.err.log 2>&1
# Zusätzlich manuell vor jedem Wazuh-Upgrade ausführen.
#
# Einstellungen können in /etc/backup/wazuh-backup.conf überschrieben werden.
#
# ACHTUNG: Das Archiv enthält client.keys und private Zertifikatsschlüssel.
# Verzeichnis ist 0700, Archive 0600. Vor einem externen Sync verschlüsseln.
#
# Getestet: bash -n, shellcheck. Nicht auf wazuh-mdm selbst getestet.

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
readonly LOG_FILE="/var/log/wazuh-backup.log"   # wird angehängt, nie überschrieben
readonly CONF_FILE="/etc/backup/wazuh-backup.conf"

# ---------- Einstellungen (Defaults, per CONF_FILE überschreibbar) ----------
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
fi

BACKUP_DIR="${BACKUP_DIR:-/backup}"
KEEP_DAYS="${KEEP_DAYS:-14}"
MIN_FREE_MB="${MIN_FREE_MB:-5120}"
INCLUDE_ARCHIVES="${INCLUDE_ARCHIVES:-0}"   # 1 = auch /var/ossec/logs/archives sichern (kann sehr groß sein)

# Indexer-Snapshot (Standard aus, bis path.repo und Repository eingerichtet sind)
INDEXER_SNAPSHOT="${INDEXER_SNAPSHOT:-0}"
INDEXER_URL="${INDEXER_URL:-https://127.0.0.1:9200}"
INDEXER_USER="${INDEXER_USER:-admin}"
INDEXER_PASS="${INDEXER_PASS:-}"            # nur in CONF_FILE (0600) setzen, nicht hier
INDEXER_CA="${INDEXER_CA:-/etc/wazuh-indexer/certs/root-ca.pem}"
SNAPSHOT_REPO="${SNAPSHOT_REPO:-wazuh-backup}"
SNAPSHOT_INDICES="${SNAPSHOT_INDICES:-wazuh-alerts-*}"
SNAPSHOT_KEEP_DAYS="${SNAPSHOT_KEEP_DAYS:-14}"

BACKUP_NAME="${BACKUP_NAME:-wazuh-server}"   # Dateiname: <NAME>_<DATUM>.tar.gz
TIMESTAMP="$(date +%F_%H%M)"
ARCHIVE="${BACKUP_DIR}/${BACKUP_NAME}_${TIMESTAMP}.tar.gz"
STAGING=""
MANAGER_STOPPED=0

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

# Aufräumen – und den Manager auf jeden Fall wieder starten, falls er gestoppt wurde
# shellcheck disable=SC2329  # wird über trap aufgerufen
cleanup() {
    if [[ "$MANAGER_STOPPED" -eq 1 ]]; then
        if systemctl start wazuh-manager >>"$LOG_FILE" 2>&1; then
            log_warn "wazuh-manager nach Abbruch wieder gestartet."
        else
            log_err "wazuh-manager konnte NICHT wieder gestartet werden – manuell prüfen: systemctl status wazuh-manager"
        fi
    fi
    if [[ -n "$STAGING" && -d "$STAGING" ]]; then
        rm -rf "$STAGING"
    fi
}
trap cleanup EXIT

# Pfade für tar sammeln (relativ zu /); Glob-Muster werden aufgelöst
TAR_PATHS=()
add_path() {
    local pattern="$1" p found=0
    for p in $pattern; do           # bewusst ungequotet: Glob-Auflösung
        [[ -e "$p" ]] || continue
        TAR_PATHS+=("${p#/}")
        found=1
    done
    if [[ "$found" -eq 1 ]]; then
        log_ok "Wird gesichert: $pattern"
    else
        log_warn "Nicht vorhanden, übersprungen: $pattern"
    fi
}

# tar mit Toleranz für Dateien, die sich während des Lesens ändern (Exit 1 bei GNU tar,
# z.B. alerts.json, das der Manager laufend schreibt). Exit 2 = echter Fehler.
# shellcheck disable=SC2329  # wird über run() aufgerufen
tar_create() {
    local rc
    tar --create --gzip --warning=no-file-changed "$@"
    rc=$?
    [[ $rc -le 1 ]]
}

# Aufruf der Indexer-API (gibt HTTP-Body aus, Exit != 0 bei HTTP-Fehler)
indexer_api() {
    local method="$1" path="$2"
    curl -sS --fail-with-body --cacert "$INDEXER_CA" \
        -u "${INDEXER_USER}:${INDEXER_PASS}" -X "$method" "${INDEXER_URL}${path}" \
        -H 'Content-Type: application/json' "${@:3}"
}

# ---------- Vorprüfungen ----------
echo -e "${C_BOLD}Backup wazuh-mdm${C_RESET}"

[[ $EUID -eq 0 ]] || { echo "Muss als root laufen (Cron/systemd-Timer oder sudo)."; exit 1; }
echo "===== $(date '+%F %T') Start ${SCRIPT_NAME} =====" >>"$LOG_FILE"

for cmd in tar gzip sha256sum flock systemctl cp; do
    command -v "$cmd" &>/dev/null || fail "'$cmd' fehlt. Installieren, z.B.: apt install ${cmd}"
done

[[ -d /var/ossec ]] || fail "/var/ossec nicht gefunden – ist der Wazuh-Manager als Paket installiert? (bei Docker andere Pfade)"
systemctl is-active --quiet wazuh-manager || fail "wazuh-manager läuft nicht – erst Ursache klären: systemctl status wazuh-manager"
log_ok "wazuh-manager aktiv"

# Parallele Läufe verhindern
exec 9>"/run/lock/${SCRIPT_NAME}.lock"
flock -n 9 || fail "Es läuft bereits ein Backup (Lock: /run/lock/${SCRIPT_NAME}.lock)."

install -d -m 0700 "$BACKUP_DIR" || fail "Backup-Verzeichnis nicht anlegbar: $BACKUP_DIR"
FREE_MB=$(df -Pm "$BACKUP_DIR" | awk 'NR==2 {print $4}')
(( FREE_MB >= MIN_FREE_MB )) || fail "Zu wenig Platz in $BACKUP_DIR: ${FREE_MB} MB frei, mindestens ${MIN_FREE_MB} MB nötig."
log_ok "Freier Platz in ${BACKUP_DIR}: ${FREE_MB} MB"

STAGING="$(mktemp -d "${BACKUP_DIR}/.staging.XXXXXX")" || fail "Staging-Verzeichnis nicht anlegbar."

# ---------- Schritt 1: Konfiguration und Schlüssel erfassen ----------
log_step "Konfiguration und Schlüssel erfassen"

# Wazuh-Server (Manager) – laut offizieller Backup-Anleitung
add_path "/var/ossec/etc/client.keys"
add_path "/var/ossec/etc/sslmanager*"
add_path "/var/ossec/etc/*.pem"
add_path "/var/ossec/etc/authd.pass"
add_path "/var/ossec/etc/ossec.conf"
add_path "/var/ossec/etc/internal_options.conf"
add_path "/var/ossec/etc/local_internal_options.conf"
add_path "/var/ossec/etc/rules/local_rules.xml"
add_path "/var/ossec/etc/decoders/local_decoder.xml"
add_path "/var/ossec/etc/lists"
add_path "/var/ossec/etc/shared"
add_path "/var/ossec/api/configuration"
add_path "/var/ossec/queue/agentless"
add_path "/var/ossec/queue/agents-timestamp"
add_path "/var/ossec/queue/fts"
add_path "/var/ossec/queue/rids"
add_path "/var/ossec/stats"
add_path "/var/ossec/var/multigroups"
add_path "/etc/filebeat"
add_path "/etc/postfix"

# Wazuh-Indexer
add_path "/etc/wazuh-indexer/certs"
add_path "/etc/wazuh-indexer/jvm.options"
add_path "/etc/wazuh-indexer/jvm.options.d"
add_path "/etc/wazuh-indexer/log4j2.properties"
add_path "/etc/wazuh-indexer/opensearch.yml"
add_path "/etc/wazuh-indexer/opensearch.keystore"
add_path "/etc/wazuh-indexer/opensearch-observability"
add_path "/etc/wazuh-indexer/opensearch-reports-scheduler"
add_path "/etc/wazuh-indexer/opensearch-security"
add_path "/usr/lib/sysctl.d/wazuh-indexer.conf"

# Wazuh-Dashboard
add_path "/etc/wazuh-dashboard/certs"
add_path "/etc/wazuh-dashboard/opensearch_dashboards.yml"
add_path "/usr/share/wazuh-dashboard/config/opensearch_dashboards.keystore"
add_path "/usr/share/wazuh-dashboard/data/wazuh/config/wazuh.yml"

# Logs (alerts immer, archives nur bei INCLUDE_ARCHIVES=1)
add_path "/var/ossec/logs"

# Systeminfo und Versionen für den Restore (gleiche Version installieren!)
{
    cat /etc/os-release
    echo; echo "Host: $(hostname -f) / $(hostname -I)"
    echo; dpkg-query -W -f='${Package} ${Version}\n' 'wazuh-*' filebeat 2>/dev/null
} > "${STAGING}/host-info.txt"
log_ok "Systeminfo und Paketversionen erfasst"

# ---------- Schritt 2: Agent-Datenbanken sichern (Manager kurz gestoppt) ----------
log_step "Agent-Datenbanken sichern (Manager kurz gestoppt)"

MANAGER_STOPPED=1
run "wazuh-manager gestoppt" systemctl stop wazuh-manager
run "queue/db kopiert" cp -a --parents /var/ossec/queue/db "$STAGING"
run "wazuh-manager gestartet" systemctl start wazuh-manager
MANAGER_STOPPED=0

sleep 5
systemctl is-active --quiet wazuh-manager || fail "wazuh-manager nach Neustart nicht aktiv – sofort prüfen: systemctl status wazuh-manager"
log_ok "wazuh-manager wieder aktiv"

# ---------- Schritt 3: Archiv erstellen ----------
log_step "Archiv erstellen"

TAR_EXCLUDES=()
if [[ "$INCLUDE_ARCHIVES" -ne 1 ]]; then
    TAR_EXCLUDES+=(--exclude='var/ossec/logs/archives')
    log_warn "Rohlogs (logs/archives) ausgeschlossen – mit INCLUDE_ARCHIVES=1 einschließen."
fi

run "Archiv geschrieben: $(basename "$ARCHIVE")" \
    tar_create --file "$ARCHIVE" \
        "${TAR_EXCLUDES[@]}" \
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
if grep -q 'var/ossec/etc/client\.keys$' "$ARCHIVE_LIST"; then
    log_ok "client.keys im Archiv enthalten"
else
    fail "client.keys fehlt im Archiv – Backup unbrauchbar."
fi
if grep -q 'var/ossec/queue/db/' "$ARCHIVE_LIST"; then
    log_ok "Agent-Datenbanken im Archiv enthalten"
else
    fail "queue/db fehlt im Archiv."
fi
( cd "$BACKUP_DIR" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" ) \
    || fail "Prüfsumme konnte nicht geschrieben werden."
chmod 0600 "${ARCHIVE}.sha256"
log_ok "SHA256-Prüfsumme geschrieben"

# ---------- Schritt 5: Indexer-Snapshot (optional) ----------
log_step "Indexer-Snapshot"

# Voraussetzung (einmalig, siehe Wazuh-Doku "Migrating Wazuh indices"):
#   mkdir /mnt/snapshots && chown wazuh-indexer:wazuh-indexer /mnt/snapshots
#   path.repo: /mnt/snapshots  in /etc/wazuh-indexer/opensearch.yml, Indexer neu starten
#   Repository "wazuh-backup" (Typ fs, Ort /mnt/snapshots) im Dashboard unter Snapshot Management anlegen
#   In CONF_FILE: INDEXER_SNAPSHOT=1, INDEXER_PASS=... (Datei 0600)
if [[ "$INDEXER_SNAPSHOT" -eq 1 ]]; then
    command -v curl &>/dev/null || fail "'curl' fehlt (apt install curl)."
    [[ -n "$INDEXER_PASS" ]] || fail "INDEXER_PASS nicht gesetzt (in $CONF_FILE eintragen)."
    SNAP_NAME="snap-$(date +%Y.%m.%d-%H%M)"
    run "Snapshot ${SNAP_NAME} erstellt" \
        indexer_api PUT "/_snapshot/${SNAPSHOT_REPO}/${SNAP_NAME}?wait_for_completion=true" \
        -d "{\"indices\":\"${SNAPSHOT_INDICES}\",\"include_global_state\":false}"

    # Alte Snapshots löschen (Name enthält das Datum)
    CUTOFF="$(date -d "-${SNAPSHOT_KEEP_DAYS} days" +%Y.%m.%d)"
    SNAP_LIST="$(indexer_api GET "/_cat/snapshots/${SNAPSHOT_REPO}?h=id" 2>>"$LOG_FILE")" \
        || fail "Snapshot-Liste konnte nicht gelesen werden."
    while read -r snap; do
        [[ "$snap" =~ ^snap-([0-9]{4}\.[0-9]{2}\.[0-9]{2}) ]] || continue
        if [[ "${BASH_REMATCH[1]}" < "$CUTOFF" ]]; then
            run "Alter Snapshot gelöscht: $snap" indexer_api DELETE "/_snapshot/${SNAPSHOT_REPO}/${snap}"
        fi
    done <<< "$SNAP_LIST"
else
    log_warn "Deaktiviert (INDEXER_SNAPSHOT=0) – indexierte Alerts werden nicht gesichert."
fi

# ---------- Schritt 6: Alte Backups rotieren ----------
log_step "Alte Backups rotieren (älter als ${KEEP_DAYS} Tage)"

DELETED=$(find "$BACKUP_DIR" -maxdepth 1 -type f \
    \( -name "${BACKUP_NAME}_*.tar.gz" -o -name "${BACKUP_NAME}_*.tar.gz.sha256" -o -name "${BACKUP_NAME}_*.tar.gz.age" \) \
    -mtime +"$KEEP_DAYS" -print -delete | wc -l)
log_ok "${DELETED} alte Datei(en) gelöscht"

# ---------- Schritt 7: Sync zu Strato (vorbereitet) ----------
log_step "Sync zu Strato HiDrive"

log_warn "Noch nicht aktiv – Backup liegt nur lokal auf diesem Server."
# Vorbereitung (einmalig):
#   1. SSH-Key erzeugen:  ssh-keygen -t ed25519 -f /root/.ssh/hidrive_backup -N ""
#   2. Public Key im HiDrive-Konto hinterlegen, Zielordner anlegen, Zugang einmal testen.
#   3. age installieren (apt install age), Schlüsselpaar mit age-keygen erzeugen.
#      Nur den Public Key hier eintragen, den Private Key NICHT auf diesem Server lassen.
#
# AGE_RECIPIENT="${AGE_RECIPIENT:-age1...}"
# STRATO_USER="${STRATO_USER:-<hidrive-benutzer>}"
# STRATO_TARGET="${STRATO_USER}@rsync.hidrive.strato.com:/users/${STRATO_USER}/backups/wazuh-mdm/"
#
# run "Archiv verschlüsselt (age)" age -r "$AGE_RECIPIENT" -o "${ARCHIVE}.age" "$ARCHIVE"
# chmod 0600 "${ARCHIVE}.age"
# run "Sync zu Strato HiDrive" \
#     rsync -a --partial \
#         -e "ssh -i /root/.ssh/hidrive_backup -o BatchMode=yes" \
#         --include="${BACKUP_NAME}_*.tar.gz.age" --include="${BACKUP_NAME}_*.tar.gz.sha256" --exclude='*' \
#         "${BACKUP_DIR}/" "$STRATO_TARGET"
#
# Indexer-Snapshots (falls aktiv) separat mitnehmen, z.B.:
# run "Snapshots zu Strato HiDrive" \
#     rsync -a --partial -e "ssh -i /root/.ssh/hidrive_backup -o BatchMode=yes" \
#         /mnt/snapshots/ "${STRATO_TARGET%/}/indexer-snapshots/"
#
# Hinweis: bewusst ohne --delete, damit lokal rotierte Backups remote erhalten bleiben.

# ---------- Schritt 8: Zusammenfassung ----------
log_step "Zusammenfassung"

SIZE="$(du -h "$ARCHIVE" | cut -f1)"
COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -name "${BACKUP_NAME}_*.tar.gz" | wc -l)
log_ok "Archiv: ${ARCHIVE} (${SIZE})"
log_ok "Vorhandene Backups: ${COUNT} (Aufbewahrung ${KEEP_DAYS} Tage)"
log_ok "wazuh-manager: $(systemctl is-active wazuh-manager)"
log_warn "Nur lokale Kopie – schützt nicht vor Platten- oder Serververlust."
echo "===== $(date '+%F %T') Ende OK =====" >>"$LOG_FILE"
echo -e "\n${C_GREEN}${C_BOLD}Backup erfolgreich abgeschlossen!${C_RESET}"

exit 0
