#!/usr/bin/env bash

# Sammelt die Dokumentationsdaten eines Relution-Servers (Docker oder nativ,
# Ubuntu/Debian oder AlmaLinux/RHEL) und schreibt:
#   - einen Markdown-Bericht        $OUT_DIR/<host>_<datum>.md  (+ latest.md)
#   - eine CSV-Zeile                $OUT_DIR/<host>_<datum>.csv (+ latest.csv)
#   - Kennzahlen für node_exporter  $TEXTFILE_DIR/serverdoku.prom
#
# Liest nur – ändert am System nur $OUT_DIR. Inhalte von Konfigurationsdateien
# (Passwörter in application.yml!) werden NICHT ausgegeben, nur Existenz,
# Rechte, Datum und Prüfsumme (für Änderungs-/Drift-Erkennung).
# Was nicht ermittelt werden kann, steht als "nicht ermittelbar" im Bericht
# und fehlt in der .prom-Datei – es wird nie stillschweigend 0 gemeldet.
#
# Aufruf:   sudo ./serverdoku.sh
#           sudo OUT_DIR=/tmp/doku RELUTION_DIR=/srv/relution ./serverdoku.sh
# Manuelle Angaben (Hoster, externe Backups …): /etc/serverdoku.conf
#
# Quellen:
#   https://docs.docker.com/engine/network/packet-filtering-firewalls/
#   https://docs.openssl.org/3.0/man1/openssl-x509/
#   https://github.com/prometheus/node_exporter#textfile-collector
# Mit Statusanzeige und Fehlerprüfung nach jedem Schritt.
# Statusmeldungen gehen nach stderr, der Bericht in Dateien unter $OUT_DIR.
# Getestet auf: Ubuntu 24.04 (apt-Pfad). dnf-Pfad (AlmaLinux) syntaktisch geprüft, nicht live.

set -uo pipefail   # bewusst ohne -e: Fehler werden explizit behandelt
export LC_ALL=C.UTF-8   # einheitliche Ausgabe von free/apt/df, unabhängig von der Locale

# ---------- Farben / Formatierung ----------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    readonly C_RESET='\033[0m'  C_BOLD='\033[1m'
    readonly C_GREEN='\033[0;32m' C_RED='\033[0;31m'
    readonly C_YELLOW='\033[0;33m' C_BLUE='\033[0;34m'
else
    readonly C_RESET='' C_BOLD='' C_GREEN='' C_RED='' C_YELLOW='' C_BLUE=''
fi

readonly SCRIPT_NAME="serverdoku"
readonly LOG_FILE="/tmp/${SCRIPT_NAME}.log"
: > "$LOG_FILE"

# ---------- Pfade / Grenzwerte (per Umgebungsvariable überschreibbar) ----------
readonly RELUTION_DIR="${RELUTION_DIR:-/opt/relution}"
readonly PG_BACKUP_DIR="${PG_BACKUP_DIR:-/media/postgresql-backup}"
readonly MINIO_BACKUP_DIR="${MINIO_BACKUP_DIR:-/media/minio-backup}"
readonly LOCAL_SCRIPT_DIR="${LOCAL_SCRIPT_DIR:-/usr/local/bin}"
readonly STATIC_CONF="${STATIC_CONF:-/etc/serverdoku.conf}"
readonly OUT_DIR="${OUT_DIR:-/var/lib/serverdoku}"
readonly TEXTFILE_DIR="${TEXTFILE_DIR:-${OUT_DIR}/textfile}"
readonly NA="nicht ermittelbar"
readonly BACKUP_MAX_AGE_H="${BACKUP_MAX_AGE_H:-26}"
readonly CERT_WARN_DAYS="${CERT_WARN_DAYS:-30}"
readonly DISK_WARN_PCT="${DISK_WARN_PCT:-85}"
# Ports, die öffentlich lauschen dürfen, ohne gemeldet zu werden
readonly ALLOWED_PUBLIC_PORTS=" 22 80 443 "

STEP_NUM=0
TOTAL_STEPS=9   # bei jedem neuen log_step anpassen!

WARNINGS=()
CONTAINERS=()
declare -A SUM=()
readonly SUM_KEYS=(host os relution_image db_image docker containers_down disk_root_pct
    pending_updates security_updates reboot_required cert_days_live public_extra_ports
    db_backup_age_h minio_backup_age_h monitoring warnings collected)

# ---------- Ausgabe-Funktionen (stderr) ----------
log_step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo -e "\n${C_BOLD}${C_BLUE}[${STEP_NUM}/${TOTAL_STEPS}]${C_RESET} ${C_BOLD}$1${C_RESET}" >&2
}
log_ok()   { echo -e "  ${C_GREEN}✔${C_RESET} $1" >&2; }
log_err()  { echo -e "  ${C_RED}✘${C_RESET} $1" >&2; }
log_warn() { echo -e "  ${C_YELLOW}⚠${C_RESET} $1" >&2; }

fail() {
    log_err "$1"
    echo -e "\n${C_RED}${C_BOLD}Vorgang abgebrochen.${C_RESET} Log: ${LOG_FILE}" >&2
    exit 1
}

# Auffälligkeit: Warnung anzeigen und für den Berichtskopf merken
finding() { log_warn "$1"; WARNINGS+=("$1"); }

# ---------- Prometheus-Kennzahlen ----------
PROM=()
# Label-Wert escapen (Backslash, Anführungszeichen, Zeilenumbruch)
lbl() { local v="${1//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s' "${v//$'\n'/ }"; }
# metric <name> <wert> [labels] – nicht-numerische/leere Werte werden ausgelassen
metric() {
    local name="serverdoku_$1" val="${2:-}" labels="${3:-}"
    [[ "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || return 0
    if [[ -n "$labels" ]]; then PROM+=("${name}{${labels}} ${val}"); else PROM+=("${name} ${val}"); fi
}
unit_state() { local s; s="$(systemctl is-enabled "$1" 2>/dev/null | head -1)"; printf '%s' "${s:-nicht installiert}"; }
num_or_na() { if [[ -n "${1:-}" ]]; then printf '%s' "$1"; else printf '%s' "$NA"; fi; }

# Führt einen Befehl mit Seiteneffekt aus, Ausgabe ins Log, Abbruch bei Fehler
run() {
    local desc="$1"
    shift
    echo "### $desc: $*" >>"$LOG_FILE"
    if "$@" >>"$LOG_FILE" 2>&1; then
        log_ok "$desc"
    else
        log_err "$desc"
        echo -e "${C_YELLOW}  --- Letzte Log-Zeilen ---${C_RESET}" >&2
        tail -n 15 "$LOG_FILE" | sed 's/^/    /' >&2
        fail "Befehl fehlgeschlagen: $*"
    fi
}

# ---------- Markdown-Helfer ----------
BODY="$(mktemp)"
TMP_REPORT="$(mktemp)"
TMP_CSV="$(mktemp)"
TMP_PROM="$(mktemp)"
trap 'rm -f "$BODY" "$TMP_REPORT" "$TMP_CSV" "$TMP_PROM"' EXIT

md()      { printf '%s\n' "$@" >>"$BODY"; }
esc()     { local v="${1//|/\\|}"; v="${v//$'\n'/<br>}"; printf '%s' "${v:-–}"; }
kv_head() { md "" "| Feld | Wert |" "|---|---|"; }
kv()      { printf '| %s | %s |\n' "$1" "$(esc "${2:-}")" >>"$BODY"; }
section() { md "" "## $1"; }
block() {
    md '```'
    if [[ -n "${1:-}" ]]; then printf '%s\n' "$1" >>"$BODY"; else md "(keine Daten)"; fi
    md '```'
}
sha12()   { sha256sum "$1" 2>/dev/null | cut -c1-12; }
mtime()   { date -r "$1" '+%F %R' 2>/dev/null; }

# ---------- Vorprüfungen ----------
echo -e "${C_BOLD}Serverdokumentation – Datensammlung${C_RESET}" >&2

[[ $EUID -eq 0 ]] || fail "Root-Rechte erforderlich (Docker, Ports, Zertifikate). Aufruf: sudo $0"

[[ -f /etc/os-release ]] || fail "/etc/os-release nicht gefunden."
# shellcheck disable=SC1091
. /etc/os-release
log_ok "System erkannt: ${PRETTY_NAME:-${ID:-unbekannt}}"

for cmd in ss openssl awk find findmnt sha256sum; do
    command -v "$cmd" &>/dev/null || fail "Benötigtes Programm fehlt: $cmd (apt install iproute2 openssl util-linux)"
done

HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"
HOST_SHORT="$(hostname -s)"
NOW="$(date '+%F %R')"
DATE_TAG="$(date +%F)"
SUM[host]="$HOST_FQDN"
SUM[os]="${PRETTY_NAME:-unbekannt}"
SUM[collected]="$NOW"

# Manuelle Angaben aus key=value-Datei (wird geparst, nicht ausgeführt)
declare -A STATIC=()
if [[ -r "$STATIC_CONF" ]]; then
    while IFS='=' read -r k v; do
        [[ "$k" =~ ^[[:space:]]*(#|$) ]] && continue
        k="${k//[[:space:]]/}"
        v="${v%%[[:space:]]#*}"                      # Kommentar am Zeilenende entfernen
        v="${v%"${v##*[![:space:]]}"}"; v="${v#"${v%%[![:space:]]*}"}"   # Leerzeichen trimmen
        v="${v%\"}"; v="${v#\"}"
        STATIC["$k"]="$v"
    done <"$STATIC_CONF"
    log_ok "Manuelle Angaben gelesen: $STATIC_CONF"
else
    log_warn "Keine $STATIC_CONF – manuelle Felder bleiben leer."
fi

# ---------- Schritt 1: System & Updates ----------
log_step "System & Updates"
section "1. System"
kv_head
kv "Hostname (FQDN)" "$HOST_FQDN"
kv "Betriebssystem" "${PRETTY_NAME:-unbekannt}"
kv "Kernel" "$(uname -r)"
kv "Virtualisierung" "$(systemd-detect-virt 2>/dev/null)"
kv "Uptime" "$(uptime -p 2>/dev/null)"
kv "Zeitzone" "$(timedatectl show -p Timezone --value 2>/dev/null)"
NTP="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
kv "Zeit synchronisiert (NTP)" "${NTP:-unbekannt}"
[[ "$NTP" == "yes" ]] || finding "Systemzeit nicht per NTP synchronisiert (relevant für Zertifikate und MDM-Token)."

# Basis ist der lokale Paket-Cache – das Skript lädt nichts nach (kein apt update / dnf makecache)
PKG_MGR=""; PENDING=""; SECURITY=""; REBOOT=""; LISTS_DATE=""; LAST_UPGRADE=""; AUTO_UPD=""
if command -v apt-get &>/dev/null; then
    PKG_MGR="apt"
    UPG="$(apt list --upgradable 2>/dev/null)"
    PENDING="$(grep -c 'upgradable from' <<<"$UPG")"
    SECURITY="$(grep -c -- '-security' <<<"$UPG")"
    LISTS_DATE="$(mtime /var/cache/apt/pkgcache.bin)"
    LAST_UPGRADE="$(zgrep -h '^Start-Date' /var/log/apt/history.log* 2>/dev/null | sort | tail -1 | cut -d' ' -f2-)"
    REBOOT="nein"; [[ -f /var/run/reboot-required ]] && REBOOT="ja"
    AUTO_UPD="unattended-upgrades: $(unit_state unattended-upgrades)"
elif command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
    # -C = nur Cache. Exit 100 = Updates vorhanden, 0 = keine, alles andere = Fehler
    UPG="$(dnf -q -C check-update 2>/dev/null)"; rc=$?
    if (( rc == 0 || rc == 100 )); then
        PENDING="$(grep -cE '^[[:alnum:]_.+-]+\.(noarch|x86_64|aarch64|i686)[[:space:]]' <<<"$UPG")"
        SEC="$(dnf -q -C updateinfo list --security 2>/dev/null)" && SECURITY="$(grep -c . <<<"$SEC")"
    fi
    LISTS_DATE="$(find /var/cache/dnf -maxdepth 2 -name 'repomd.xml' -printf '%TY-%Tm-%Td %TH:%TM\n' 2>/dev/null | sort | tail -1)"
    LAST_UPGRADE="$(rpm -qa --last 2>/dev/null | head -1 | sed 's/^[^ ]* *//')"
    if command -v needs-restarting &>/dev/null; then
        needs-restarting -r &>/dev/null; rc=$?
        case "$rc" in 0) REBOOT="nein" ;; 1) REBOOT="ja" ;; esac
    fi
    AUTO_UPD="dnf-automatic: $(unit_state dnf-automatic.timer)"
fi
kv "Paketverwaltung" "$(num_or_na "$PKG_MGR")"
kv "Ausstehende Updates" "$(num_or_na "$PENDING") (davon Sicherheit: $(num_or_na "$SECURITY"), Paket-Cache vom ${LISTS_DATE:-?})"
kv "Letzte Paketaktion" "$LAST_UPGRADE"
kv "Neustart erforderlich" "$(num_or_na "$REBOOT")"
kv "Automatische Updates" "$AUTO_UPD"
SUM[pending_updates]="$(num_or_na "$PENDING")"; SUM[security_updates]="$(num_or_na "$SECURITY")"
SUM[reboot_required]="$(num_or_na "$REBOOT")"
metric updates_pending "$PENDING"
metric updates_security "$SECURITY"
case "$REBOOT" in ja) metric reboot_required 1 ;; nein) metric reboot_required 0 ;; esac
[[ -z "$PENDING" ]] && finding "Update-Status nicht ermittelbar (Paketverwaltung/Cache prüfen)."
[[ -n "$SECURITY" ]] && (( SECURITY > 0 )) && finding "${SECURITY} Sicherheitsupdates ausstehend."
[[ "$REBOOT" == "ja" ]] && finding "Neustart ausstehend."
log_ok "System erfasst"

# ---------- Schritt 2: Ressourcen & Netzwerk ----------
log_step "Ressourcen & Netzwerk"
section "2. Ressourcen & Netzwerk"
kv_head
kv "CPU-Kerne" "$(nproc)"
kv "RAM" "$(free -h | awk '/^Mem:/{print $2" gesamt, "$7" verfügbar"}')"
kv "Swap" "$(free -h | awk '/^Swap:/{print $2" gesamt, "$3" belegt"}')"
kv "Default-Gateway" "$(ip route show default 2>/dev/null | awk '{print $3" ("$5")"; exit}')"
kv "DNS-Server" "$(resolvectl dns 2>/dev/null | awk -F': ' 'NF>1 && $2!=""{print $2}' | sort -u | tr '\n' ' ')"
md "" "### Interfaces"
block "$(ip -br addr show 2>/dev/null | grep -vE '^(lo|veth|br-|docker)')"
md "" "### Dateisysteme"
DF_EXCL=(-x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs)
block "$(df -hT "${DF_EXCL[@]}" 2>/dev/null)"
SUM[disk_root_pct]="$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')"
metric disk_root_used_percent "${SUM[disk_root_pct]}"
while read -r mp pct; do
    finding "Dateisystem ${mp} zu ${pct}% belegt."
done < <(df -P "${DF_EXCL[@]}" 2>/dev/null | awk -v lim="$DISK_WARN_PCT" 'NR>1{gsub("%","",$5); if($5+0>=lim) print $6, $5}')
log_ok "Ressourcen erfasst (Root-FS: ${SUM[disk_root_pct]}%)"

# ---------- Schritt 3: Docker & Container ----------
log_step "Docker & Container"
section "3. Docker, Container & Dienste"
RELUTION_IMG=""; DB_IMG=""; DB_C=""; DOWN=0; DOCKER_OK=0

# Native Installation (ohne Docker): systemd-Units für Relution und Datenbank
NATIVE_REL="$(systemctl list-units --type=service --all --plain --no-legend 'relution*' 2>/dev/null \
    | awk '{print $1" ("$3"/"$4")"}' | tr '\n' ' ')"
NATIVE_DB=""
for s in postgresql mariadb mysql mysqld; do
    systemctl is-active --quiet "$s" 2>/dev/null && NATIVE_DB+="$s "
done

if ! command -v docker &>/dev/null; then
    kv_head; kv "Docker" "nicht installiert"
    [[ -z "$NATIVE_REL" ]] && finding "Weder Docker noch ein nativer Relution-Dienst gefunden."
elif ! DOCKER_V="$(docker version --format '{{.Server.Version}}' 2>>"$LOG_FILE")"; then
    finding "Docker-Daemon nicht erreichbar (systemctl status docker)."
    kv_head; kv "Docker" "Daemon nicht erreichbar"
else
    DOCKER_OK=1
    SUM[docker]="$DOCKER_V"
    kv_head
    kv "Docker Engine" "$DOCKER_V"
    kv "Docker Compose" "$(docker compose version --short 2>/dev/null)"
    mapfile -t CONTAINERS < <(docker ps -a --format '{{.Names}}' 2>/dev/null | sort)

    md "" "### Container" "" "| Container | Image | Status | Restart-Policy | Compose-Datei | Ports |" "|---|---|---|---|---|---|"
    for c in "${CONTAINERS[@]}"; do
        IFS=$'\t' read -r img state rp cfg < <(docker inspect -f \
            '{{.Config.Image}}{{"\t"}}{{.State.Status}}{{"\t"}}{{.HostConfig.RestartPolicy.Name}}{{"\t"}}{{index .Config.Labels "com.docker.compose.project.config_files"}}' \
            "$c" 2>/dev/null)
        ports="$(docker port "$c" 2>/dev/null | tr '\n' ' ')"
        printf '| %s | %s | %s | %s | %s | %s |\n' "$c" "$(esc "$img")" "$(esc "$state")" \
            "$(esc "$rp")" "$(esc "$cfg")" "$(esc "$ports")" >>"$BODY"
        if [[ "$state" != "running" ]]; then
            DOWN=$((DOWN + 1)); finding "Container ${c} läuft nicht (Status: ${state})."
        fi
        [[ -z "$rp" || "$rp" == "no" ]] && finding "Container ${c} hat keine Restart-Policy – startet nach Reboot nicht automatisch."
        case "$img" in
            *nginx*|*minio*) ;;
            *postgres*|*mariadb*|*mysql*) DB_IMG="$img"; DB_C="$c" ;;
            *relution*) RELUTION_IMG="$img" ;;
        esac
    done
    SUM[containers_down]="$DOWN"
    metric containers_total "${#CONTAINERS[@]}"
    metric containers_not_running "$DOWN"

    md "" "### Relution & Datenbank"
    kv_head
    if [[ -n "$NATIVE_REL" && -z "$RELUTION_IMG" ]]; then
        kv "Relution (nativ)" "$NATIVE_REL"
        SUM[relution_image]="nativ"
    elif [[ -n "$RELUTION_IMG" ]]; then
        kv "Relution-Image" "$RELUTION_IMG"
        kv "Image erstellt" "$(docker image inspect -f '{{.Created}}' "$RELUTION_IMG" 2>/dev/null | cut -c1-10)"
        kv "Image-Version (Label)" "$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$RELUTION_IMG" 2>/dev/null)"
        [[ "$RELUTION_IMG" == *:latest || "$RELUTION_IMG" != *:* ]] && \
            kv "Hinweis" "Tag 'latest' – tatsächliche Version im Relution-Portal ablesen"
        SUM[relution_image]="$RELUTION_IMG"
    else
        finding "Kein Relution-Container erkannt."
    fi
    if [[ -n "$DB_C" ]]; then
        kv "Datenbank-Image" "$DB_IMG"
        kv "Datenbank-Version" "$(docker exec "$DB_C" sh -c 'postgres --version 2>/dev/null || mariadbd --version 2>/dev/null || mysqld --version 2>/dev/null' 2>/dev/null)"
        SUM[db_image]="$DB_IMG"
    elif [[ -z "$NATIVE_DB" ]]; then
        finding "Keine Datenbank erkannt (weder Container noch Dienst)."
    fi
    log_ok "${#CONTAINERS[@]} Container erfasst, davon ${DOWN} nicht laufend"
fi

# Native Dienste auch auf Docker-Hosts ausweisen (Mischbetrieb)
if [[ -n "$NATIVE_REL" && $DOCKER_OK -eq 0 ]]; then
    md "" "### Relution & Datenbank (nativ)"
    kv_head
    kv "Relution-Dienst" "$NATIVE_REL"
    SUM[relution_image]="nativ"
    grep -q 'inactive\|failed' <<<"$NATIVE_REL" && finding "Nativer Relution-Dienst läuft nicht: ${NATIVE_REL}"
fi
if [[ -n "$NATIVE_DB" ]]; then
    kv "Datenbank-Dienst (nativ)" "$NATIVE_DB"
    SUM[db_image]="${SUM[db_image]:-nativ: ${NATIVE_DB% }}"
fi
log_ok "Dienste erfasst"

# ---------- Schritt 4: Konfigurationsdateien & Datenpfade ----------
log_step "Konfigurationsdateien & Datenpfade"
section "4. Konfigurationsdateien (nur Metadaten, keine Inhalte)"
if [[ -d "$RELUTION_DIR" ]]; then
    md "" "| Datei | Rechte | Größe | Geändert | SHA256 (12) |" "|---|---|---|---|---|"
    while IFS= read -r f; do
        perm="$(stat -c '%a %U' "$f")"
        printf '| %s | %s | %s | %s | %s |\n' "$f" "$perm" "$(du -h "$f" | cut -f1)" \
            "$(mtime "$f")" "$(sha12 "$f")" >>"$BODY"
        # Konfiguration mit Passwörtern darf nicht für alle lesbar sein
        if [[ "$f" == *application.y*ml || "$f" == *.env || "$f" == *.key ]] && (( 10#${perm%% *} % 10 >= 4 )); then
            finding "${f} ist für alle Benutzer lesbar (Rechte ${perm%% *}) – enthält Zugangsdaten."
        fi
    done < <(find "$RELUTION_DIR" -maxdepth 3 -path "$RELUTION_DIR/volumes" -prune -o -type f \
        \( -name '*.yml' -o -name '*.yaml' -o -name '*.conf' -o -name '*.pem' -o -name '*.crt' \
           -o -name '*.key' -o -name '*.env' -o -name '.env' \) -print 2>/dev/null | sort)
    for req in application.yml dhparams.pem; do
        [[ -f "$RELUTION_DIR/$req" ]] || finding "Erwartete Datei fehlt: $RELUTION_DIR/$req"
    done
    SERVER_NAMES="$(grep -rhoE 'server_name[[:space:]]+[^;]+' "$RELUTION_DIR" --include='*.conf' 2>/dev/null \
        | awk '{$1=""; print}' | tr ' ' '\n' | grep -v '^_\?$' | sort -u | tr '\n' ' ')"
    md "" "**nginx server_name:** $(esc "$SERVER_NAMES")"
else
    finding "Relution-Verzeichnis $RELUTION_DIR fehlt (RELUTION_DIR setzen?)."
    SERVER_NAMES=""
fi

md "" "### Datenpfade (Volumes & Bind-Mounts)" "" \
    "| Container | Typ | Quelle (Host) | Ziel (Container) | Größe |" "|---|---|---|---|---|"
for c in "${CONTAINERS[@]}"; do
    while IFS=$'\t' read -r typ src dst; do
        [[ -z "$src" ]] && continue
        size="$(timeout 120 du -sh "$src" 2>/dev/null | cut -f1)"
        printf '| %s | %s | %s | %s | %s |\n' "$c" "$typ" "$(esc "$src")" "$(esc "$dst")" "${size:-?}" >>"$BODY"
    done < <(docker inspect -f '{{range .Mounts}}{{.Type}}{{"\t"}}{{.Source}}{{"\t"}}{{.Destination}}{{"\n"}}{{end}}' "$c" 2>/dev/null)
done
log_ok "Dateien und Datenpfade erfasst"

# ---------- Schritt 5: Zertifikate ----------
log_step "Zertifikate"
section "5. Zertifikate"
md "" "| Quelle | Subject | Aussteller | Gültig bis | Resttage |" "|---|---|---|---|---|"
CERT_LAST_DAYS=""

# Liest ein PEM von stdin; gibt 1 zurück, wenn es kein Zertifikat ist (z.B. Key)
cert_row() {
    local src="$1" pem end end_ts subj iss days
    pem="$(cat)"
    end="$(openssl x509 -noout -enddate <<<"$pem" 2>/dev/null | cut -d= -f2-)"
    [[ -z "$end" ]] && return 1
    subj="$(openssl x509 -noout -subject -nameopt RFC2253 <<<"$pem" 2>/dev/null | cut -d= -f2-)"
    iss="$(openssl x509 -noout -issuer -nameopt RFC2253 <<<"$pem" 2>/dev/null | cut -d= -f2-)"
    end_ts="$(date -d "$end" +%s)"
    days=$(( ( end_ts - $(date +%s) ) / 86400 ))
    # Ablaufzeitpunkt statt Resttage: Grafana rechnet live mit time() - …
    metric cert_not_after_timestamp_seconds "$end_ts" "source=\"$(lbl "$src")\""
    printf '| %s | %s | %s | %s | %s |\n' "$(esc "$src")" "$(esc "$subj")" "$(esc "$iss")" \
        "$(date -d "$end" +%F)" "$days" >>"$BODY"
    CERT_LAST_DAYS="$days"
    (( days < CERT_WARN_DAYS )) && finding "Zertifikat ${src} läuft in ${days} Tagen ab."
    return 0
}

while IFS= read -r f; do
    cert_row "$f" <"$f" || true
done < <(find "$RELUTION_DIR/certs" "$RELUTION_DIR/configs" -maxdepth 2 -type f \
    \( -name '*.crt' -o -name '*.pem' -o -name '*.cer' \) ! -name 'dhparam*' 2>/dev/null | sort)

# Tatsächlich ausgeliefertes Zertifikat (SNI = erster nginx server_name, sonst FQDN)
SNI="${SERVER_NAMES%% *}"; SNI="${SNI:-$HOST_FQDN}"
LIVE_PEM="$(echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$SNI" 2>/dev/null | openssl x509 2>/dev/null)"
if [[ -n "$LIVE_PEM" ]] && cert_row "live :443 (SNI ${SNI})" <<<"$LIVE_PEM"; then
    SUM[cert_days_live]="$CERT_LAST_DAYS"
else
    finding "Kein Zertifikat auf 127.0.0.1:443 abrufbar (nginx läuft?)."
fi

if [[ -f "$RELUTION_DIR/dhparams.pem" ]]; then
    DH_BITS="$(openssl dhparam -in "$RELUTION_DIR/dhparams.pem" -noout -text 2>/dev/null | grep -oE '[0-9]+ bit' | head -1)"
    md "" "**Diffie-Hellman-Parameter:** ${DH_BITS:-nicht lesbar}"
    [[ -n "$DH_BITS" ]] && (( ${DH_BITS%% *} < 2048 )) && finding "DH-Parameter nur ${DH_BITS}."
fi
log_ok "Zertifikate erfasst"

# ---------- Schritt 6: Ports & Zugriff ----------
log_step "Ports & Zugriff"
section "6. Netzwerk-Ports & Zugriff"
md "" "| Adresse:Port | Prozess |" "|---|---|"
PUBLIC_EXTRA=()
while read -r addr proc; do
    printf '| %s | %s |\n' "$addr" "$proc" >>"$BODY"
    ip="${addr%:*}"; port="${addr##*:}"
    case "$ip" in 0.0.0.0|\*|\[::\]) ;; *) continue ;; esac
    [[ "$ALLOWED_PUBLIC_PORTS" == *" $port "* ]] && continue
    [[ " ${PUBLIC_EXTRA[*]} " == *" $port "* ]] || PUBLIC_EXTRA+=("$port")
    if [[ "$proc" == docker-proxy ]]; then
        finding "Port ${port} ist auf allen Interfaces über Docker veröffentlicht – Docker umgeht ufw-Regeln."
    else
        finding "Port ${port} lauscht auf allen Interfaces (${proc:-Prozess unbekannt})."
    fi
done < <(ss -tlnpH 2>/dev/null | awk '{p=$6; sub(/^users:\(\("/,"",p); sub(/".*/,"",p); print $4, p}' | sort -u)
SUM[public_extra_ports]="${PUBLIC_EXTRA[*]:-keine}"
metric public_extra_ports "${#PUBLIC_EXTRA[@]}"

md "" "### Firewall"
if command -v ufw &>/dev/null; then
    UFW="$(ufw status verbose 2>/dev/null)"
    block "$UFW"
    [[ "$UFW" == *"Status: active"* ]] || finding "ufw ist nicht aktiv."
else
    block "ufw nicht installiert"
fi

md "" "### SSH & Benutzer"
SSHD="$(sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|allowusers|allowgroups) ')"
block "$SSHD"
grep -q '^passwordauthentication yes' <<<"$SSHD" && finding "SSH erlaubt Passwort-Login."
grep -q '^permitrootlogin yes' <<<"$SSHD" && finding "SSH erlaubt Root-Login mit Passwort."
kv_head
kv "fail2ban" "$(systemctl is-active fail2ban 2>/dev/null)"
kv "Login-Benutzer" "$(awk -F: '($3>=1000 || $3==0) && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd | tr '\n' ' ')"
kv "sudo-Gruppe" "$(getent group sudo | cut -d: -f4)"
log_ok "Ports und Zugriff erfasst"

# ---------- Schritt 7: Backups ----------
log_step "Backups"
section "7. Backups"

md "" "### Cronjobs"
CRON=""
for f in /var/spool/cron/crontabs/*; do
    [[ -f "$f" ]] || continue
    CRON+="$(grep -vE '^\s*(#|$)' "$f" | sed "s|^|$(basename "$f"): |")"$'\n'
done
for f in /etc/cron.d/*; do
    [[ -f "$f" ]] || continue
    CRON+="$(grep -vE '^\s*(#|$)|^[A-Z_]+=' "$f" | sed "s|^|cron.d/$(basename "$f"): |")"$'\n'
done
block "${CRON%$'\n'}"

md "" "### Systemd-Timer (ohne Standard-Timer)"
block "$(systemctl list-timers --all --no-pager --no-legend 2>/dev/null \
    | grep -vE 'apt-daily|man-db|logrotate|fstrim|e2scrub|motd-news|dpkg-db|tmpfiles|update-notifier|fwupd|sysstat|apport|ua-timer|snapd')"

md "" "### Lokale Skripte ($LOCAL_SCRIPT_DIR)" "" "| Skript | Geändert | SHA256 (12) | per Cron/Timer geplant |" "|---|---|---|---|"
while IFS= read -r f; do
    name="$(basename "$f")"
    planned="nein"
    grep -q -- "$name" <<<"$CRON" && planned="ja"
    printf '| %s | %s | %s | %s |\n' "$name" "$(mtime "$f")" "$(sha12 "$f")" "$planned" >>"$BODY"
done < <(find "$LOCAL_SCRIPT_DIR" -maxdepth 1 -type f 2>/dev/null | sort)

# $1=Bezeichnung $2=Verzeichnis $3=CSV-Schlüssel
backup_check() {
    local label="$1" dir="$2" key="$3" newest file age cnt size mnt type="${3%%_*}"
    if [[ ! -d "$dir" ]]; then
        finding "${label}: Verzeichnis ${dir} fehlt."; kv "$label" "Verzeichnis fehlt"; SUM[$key]="fehlt"; return
    fi
    mnt="$(findmnt -n -o TARGET,SOURCE,FSTYPE -T "$dir" 2>/dev/null)"
    [[ "${mnt%% *}" == "/" ]] && finding "${label}: ${dir} liegt auf dem Root-Dateisystem – Backup-Medium nicht gemountet?"
    newest="$(find "$dir" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1)"
    if [[ -z "$newest" ]]; then
        finding "${label}: keine Dateien in ${dir}."; kv "$label" "leer"; SUM[$key]="leer"; return
    fi
    file="${newest#* }"
    age=$(( ( $(date +%s) - ${newest%%.*} ) / 3600 ))
    cnt="$(find "$dir" -type f 2>/dev/null | wc -l)"
    size="$(timeout 120 du -sh "$dir" 2>/dev/null | cut -f1)"
    kv "$label" "neueste: ${file} (vor ${age} h, $(du -h "$file" | cut -f1)), ${cnt} Dateien, ${size:-?} gesamt; Mount: ${mnt:-?}"
    SUM[$key]="$age"
    metric backup_newest_timestamp_seconds "${newest%%.*}" "type=\"${type}\""
    metric backup_newest_bytes "$(stat -c %s "$file" 2>/dev/null)" "type=\"${type}\""
    metric backup_files "$cnt" "type=\"${type}\""
    (( age > BACKUP_MAX_AGE_H )) && finding "${label}: letzte Sicherung vor ${age} h (Grenze ${BACKUP_MAX_AGE_H} h)."
    [[ -s "$file" ]] || finding "${label}: neueste Sicherung ${file} ist leer (0 Byte)."
}

md "" "### Lokale Sicherungen"
kv_head
backup_check "Datenbank-Backup" "$PG_BACKUP_DIR" db_backup_age_h
backup_check "MinIO-Backup" "$MINIO_BACKUP_DIR" minio_backup_age_h
log_ok "Backups erfasst"

# ---------- Schritt 8: Monitoring ----------
log_step "Monitoring"
section "8. Monitoring"
MON=()
for svc in prometheus-node-exporter node_exporter nagent zabbix-agent2 zabbix-agent promtail alloy telegraf; do
    systemctl is-active --quiet "$svc" 2>/dev/null && MON+=("$svc")
done
for c in "${CONTAINERS[@]}"; do
    case "$c" in *exporter*|*cadvisor*|*promtail*|*alloy*) MON+=("container:$c") ;; esac
done
kv_head
kv "Aktive Monitoring-Agenten" "${MON[*]:-keine gefunden}"
SUM[monitoring]="${MON[*]:-keine}"
(( ${#MON[@]} == 0 )) && finding "Kein Monitoring-Agent gefunden."
if [[ ${#MON[@]} -gt 0 ]] && ! grep -qs 'textfile' <<<"$(ps -eo args 2>/dev/null | grep node_exporter)"; then
    log_warn "node_exporter ohne Textfile-Collector? Kennzahlen aus ${TEXTFILE_DIR} kommen dann nicht in Grafana an."
fi
log_ok "Monitoring erfasst"

# ---------- Schritt 9: Zusammenfassung ----------
log_step "Zusammenfassung"
SUM[warnings]="${#WARNINGS[@]}"
readonly STATIC_KEYS=(HOSTER STANDORT KUNDE ANSPRECHPARTNER EXTERNES_BACKUP_DB EXTERNES_BACKUP_MINIO
    VOLLBACKUP CONFIG_ABLAGE NOTIZ)
{
    echo "# Serverdokumentation: ${HOST_FQDN}"
    echo
    echo "_Automatisch erfasst am ${NOW} mit ${SCRIPT_NAME}.sh. Manuelle Angaben: ${STATIC_CONF}._"
    echo
    echo "## Auffälligkeiten (${#WARNINGS[@]})"
    if (( ${#WARNINGS[@]} )); then printf -- '- ⚠ %s\n' "${WARNINGS[@]}"; else echo "- keine"; fi
    echo
    echo "## 0. Manuelle Angaben"
    echo
    echo "| Feld | Wert |"
    echo "|---|---|"
    for k in "${STATIC_KEYS[@]}"; do printf '| %s | %s |\n' "$k" "$(esc "${STATIC[$k]:-}")"; done
    for k in $(printf '%s\n' "${!STATIC[@]}" | sort); do
        [[ " ${STATIC_KEYS[*]} " == *" $k "* ]] || printf '| %s | %s |\n' "$k" "$(esc "${STATIC[$k]}")"
    done
    cat "$BODY"
} >"$TMP_REPORT"

{
    (IFS=';'; echo "${SUM_KEYS[*]}")
    vals=()
    for k in "${SUM_KEYS[@]}"; do v="${SUM[$k]:-}"; vals+=("${v//;/,}"); done
    (IFS=';'; echo "${vals[*]}")
} >"$TMP_CSV"

# Kennzahlen: nach Name sortiert (gleichnamige Metriken müssen zusammenstehen)
metric warnings "${#WARNINGS[@]}"
metric last_run_timestamp_seconds "$(date +%s)"
PROM+=("serverdoku_info{os=\"$(lbl "${PRETTY_NAME:-}")\",relution=\"$(lbl "${SUM[relution_image]:-}")\",db=\"$(lbl "${SUM[db_image]:-}")\",docker=\"$(lbl "${SUM[docker]:-}")\"} 1")
{
    echo "# Erzeugt von ${SCRIPT_NAME}.sh am ${NOW}"
    printf '%s\n' "${PROM[@]}" | sort
} >"$TMP_PROM"

REPORT="${OUT_DIR}/${HOST_SHORT}_${DATE_TAG}.md"
CSV="${OUT_DIR}/${HOST_SHORT}_${DATE_TAG}.csv"
run "Ausgabeverzeichnis ${OUT_DIR}" install -d -m 0750 "$OUT_DIR"
run "Bericht geschrieben: ${REPORT}" install -m 0640 "$TMP_REPORT" "$REPORT"
run "CSV geschrieben: ${CSV}" install -m 0640 "$TMP_CSV" "$CSV"
# Kopien statt Symlinks – Symlinks werden beim Upload per rrsync nicht zuverlässig übertragen
run "latest.md / latest.csv aktualisiert" install -m 0640 "$TMP_REPORT" "${OUT_DIR}/latest.md"
install -m 0640 "$TMP_CSV" "${OUT_DIR}/latest.csv"
# node_exporter liest nur *.prom – erst als .tmp schreiben, dann atomar umbenennen
run "Textfile-Verzeichnis ${TEXTFILE_DIR}" install -d -m 0755 "$TEXTFILE_DIR"
run "Kennzahlen geschrieben: ${TEXTFILE_DIR}/serverdoku.prom" \
    install -m 0644 "$TMP_PROM" "${TEXTFILE_DIR}/serverdoku.prom.tmp"
mv -f "${TEXTFILE_DIR}/serverdoku.prom.tmp" "${TEXTFILE_DIR}/serverdoku.prom" \
    || fail "Kennzahlen-Datei konnte nicht umbenannt werden."

if (( ${#WARNINGS[@]} )); then
    log_warn "${#WARNINGS[@]} Auffälligkeiten – siehe Kopf des Berichts."
else
    log_ok "Keine Auffälligkeiten."
fi
echo -e "\n${C_GREEN}${C_BOLD}Datensammlung erfolgreich abgeschlossen!${C_RESET}" >&2

exit 0
