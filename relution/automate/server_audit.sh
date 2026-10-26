#!/usr/bin/env bash

# relution-audit.sh — Rein lesendes Audit für Relution-Server (Docker oder native Installation)
# auf Ubuntu/Debian und RHEL/AlmaLinux/Rocky.
#
# Prüft: OS-Status & Ressourcen, Patch-Stand, offene Updates, Relution-Betriebsart,
#        Container/Dienste, HTTPS/Zertifikat, Cronjobs & Timer, Backups (Alter, Größe, Integrität).
# Quellen:
#   apt-get(8), dnf(8), needs-restarting(1), systemctl(1), docker-inspect(1), crontab(1), find(1)
# Mit Statusanzeige und Bewertung nach jedem Prüfpunkt.
#
# Nutzung:    sudo ./relution-audit.sh [--refresh]
# Remote:     ssh root@host 'bash -s -- --refresh' < relution-audit.sh
# Exit-Codes: 0 = OK, 1 = Warnungen, 2 = kritische Befunde, 3 = Skriptfehler
#             (Nagios-Konvention, nutzbar als Custom-Check z.B. in N-central)
#
# Hinweis zum Hausstil: Anders als Setup-Skripte bricht ein Audit bei Befunden NICHT ab.
# fail() wird nur für Vorbedingungen genutzt, alle Prüfungen laufen durch.

set -uo pipefail   # bewusst ohne -e: Befunde werden gezählt, nicht abgebrochen

# ---------- Farben / Formatierung ----------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly C_RESET='\033[0m'  C_BOLD='\033[1m'
    readonly C_GREEN='\033[0;32m' C_RED='\033[0;31m'
    readonly C_YELLOW='\033[0;33m' C_BLUE='\033[0;34m'
else
    readonly C_RESET='' C_BOLD='' C_GREEN='' C_RED='' C_YELLOW='' C_BLUE=''
fi

readonly SCRIPT_NAME="relution-audit"
readonly SCRIPT_VERSION="1.0"

# ---------- Konfiguration ----------
# Alle Werte per Umgebungsvariable oder in /etc/relution-audit.conf (Bash-Syntax) überschreibbar.
CONF_FILE="${CONF_FILE:-/etc/relution-audit.conf}"
if [[ -r "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
fi

# Öffentliche URL der Relution-Instanz (für HTTP- und Zertifikatsprüfung).
# Default = FQDN des Hosts — passt oft NICHT zum Zertifikat, daher pro Server in der conf setzen.
RELUTION_URL="${RELUTION_URL:-https://$(hostname -f 2>/dev/null || hostname)}"
RELUTION_HEALTH_PATH="${RELUTION_HEALTH_PATH:-/}"

# Backup-Verzeichnisse (Leerzeichen-getrennt). Bewusst NICHT /var/backups selbst:
# dort legt Debian/Ubuntu täglich dpkg-Statusdateien ab, die sonst als "frisches Backup" zählen.
BACKUP_DIRS="${BACKUP_DIRS:-/var/backups/relution /backup /backups /srv/backup /opt/backup /opt/relution/backup /root/backup}"
BACKUP_FILE_REGEX="${BACKUP_FILE_REGEX:-.*\.(sql|dump|gz|tgz|tar|zst|xz|bz2|zip|7z|bak)$}"
BACKUP_MAX_AGE_H="${BACKUP_MAX_AGE_H:-26}"          # älter = Backup fehlt
BACKUP_MIN_SIZE_KB="${BACKUP_MIN_SIZE_KB:-100}"     # kleiner = verdächtig
BACKUP_VERIFY="${BACKUP_VERIFY:-1}"                 # 1 = Archiv-Integrität des neuesten Backups testen
# Erwartete Backup-Bestandteile: "Regex=Bezeichnung;Regex=Bezeichnung"
# Beispiel: "sql|dump=Datenbank-Dump;minio=MinIO-Objektspeicher;application\.yml|relution-conf=Relution-Konfiguration"
BACKUP_EXPECT="${BACKUP_EXPECT:-sql|dump|mariadb|mysql=Datenbank-Dump}"
BACKUP_KEYWORDS="${BACKUP_KEYWORDS:-backup|mysqldump|mariadb-dump|mariabackup|restic|borg|rsnapshot|rclone|duplicity}"

DISK_WARN="${DISK_WARN:-80}"
DISK_CRIT="${DISK_CRIT:-90}"
CERT_WARN_DAYS="${CERT_WARN_DAYS:-21}"
CERT_CRIT_DAYS="${CERT_CRIT_DAYS:-7}"
PATCH_WARN_DAYS="${PATCH_WARN_DAYS:-30}"
PATCH_CRIT_DAYS="${PATCH_CRIT_DAYS:-90}"
IMAGE_WARN_DAYS="${IMAGE_WARN_DAYS:-180}"           # Relution-Image älter = vermutlich veraltet

if [[ $EUID -eq 0 ]]; then
    REPORT_DIR="${REPORT_DIR:-/var/log/relution-audit}"
else
    REPORT_DIR="${REPORT_DIR:-${HOME}/relution-audit}"
fi
REPORT_KEEP_DAYS="${REPORT_KEEP_DAYS:-90}"

STEP_NUM=0
TOTAL_STEPS=7   # bei jedem neuen log_step anpassen!
CNT_OK=0
CNT_WARN=0
CNT_CRIT=0
FINDINGS=()
NOW="$(date +%s)"
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"
REPORT="/dev/null"   # wird in den Vorprüfungen gesetzt

# ---------- Ausgabe-Funktionen ----------
# Konsole farbig, Report ohne Farbcodes
say() {
    printf '%b\n' "$1"
    printf '%b\n' "$1" | sed -E 's/\x1B\[[0-9;]*m//g' >>"$REPORT"
}

# Rohdaten nur in den Report (stdin), eingerückt
detail() {
    {
        echo "    --- $1 ---"
        sed 's/^/    /'
    } >>"$REPORT"
}

log_step() {
    STEP_NUM=$((STEP_NUM + 1))
    say "\n${C_BOLD}${C_BLUE}[${STEP_NUM}/${TOTAL_STEPS}]${C_RESET} ${C_BOLD}$1${C_RESET}"
}

log_ok()   { CNT_OK=$((CNT_OK + 1));     say "  ${C_GREEN}✔${C_RESET} $1"; }
log_warn() { CNT_WARN=$((CNT_WARN + 1)); FINDINGS+=("WARN  $1"); say "  ${C_YELLOW}⚠${C_RESET} $1"; }
log_err()  { CNT_CRIT=$((CNT_CRIT + 1)); FINDINGS+=("KRIT  $1"); say "  ${C_RED}✘${C_RESET} $1"; }
log_info() { say "  · $1"; }

fail() {
    printf '%b\n' "  ${C_RED}✘${C_RESET} $1" >&2
    printf '%b\n' "\n${C_RED}${C_BOLD}Audit abgebrochen.${C_RESET}" >&2
    exit 3
}

has() { command -v "$1" &>/dev/null; }

unit_exists() {
    systemctl list-unit-files --no-legend "$1" 2>/dev/null | grep -q .
}

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1} B"; }

usage() {
    cat <<EOF
Nutzung: $SCRIPT_NAME [--refresh]

  --refresh   Paketlisten vor der Update-Prüfung aktualisieren (apt-get update / dnf makecache).
              Ohne diese Option ändert das Skript nichts am System.
  -h, --help  Diese Hilfe

Konfiguration: Variablen im Skriptkopf, per Umgebung oder in ${CONF_FILE}.
Exit-Codes: 0 OK, 1 Warnungen, 2 kritisch, 3 Skriptfehler.
EOF
}

# ---------- Argumente ----------
REFRESH=0
for arg in "$@"; do
    case "$arg" in
        --refresh) REFRESH=1 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unbekannte Option: $arg (siehe --help)" ;;
    esac
done

# ---------- Vorprüfungen ----------
# Root/sudo — ohne Root fehlen Cronjobs anderer Benutzer, Docker und Backup-Verzeichnisse
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    has sudo || fail "Root-Rechte oder sudo erforderlich."
    # Ohne Terminal (Cron, Fernaufruf) darf sudo nicht auf ein Passwort warten
    if [[ -t 0 ]]; then SUDO="sudo"; else SUDO="sudo -n"; fi
fi

# Report-Datei
mkdir -p "$REPORT_DIR" 2>/dev/null || fail "Report-Verzeichnis ${REPORT_DIR} nicht anlegbar (REPORT_DIR setzen)."
REPORT="${REPORT_DIR}/audit_${HOST_SHORT}_$(date +%Y%m%d-%H%M%S).log"
: >"$REPORT" || fail "Report-Datei ${REPORT} nicht schreibbar."

say "${C_BOLD}Relution-Server-Audit v${SCRIPT_VERSION} — ${HOST_SHORT} — $(date '+%d.%m.%Y %H:%M')${C_RESET}"

# Betriebssystem
[[ -f /etc/os-release ]] || fail "/etc/os-release nicht gefunden — nicht unterstützte Distribution."
# shellcheck disable=SC1091
. /etc/os-release

case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*)                PKG="apt" ;;
    *" rhel "*|*" fedora "*|*" centos "*)     PKG="dnf" ;;
    *)                                        PKG="unbekannt" ;;
esac
DNF="dnf"
has dnf || DNF="yum"

log_ok "System erkannt: ${PRETTY_NAME:-${ID:-unbekannt}} (Paketverwaltung: ${PKG})"
[[ $EUID -ne 0 ]] && log_warn "Läuft ohne Root — einige Prüfungen nutzen '${SUDO}' und können unvollständig sein"
log_info "Report: ${REPORT}"

# ---------- Schritt 1: Betriebssystem & Ressourcen ----------
log_step "Betriebssystem & Ressourcen"

log_info "Host: $(hostname -f 2>/dev/null || hostname) | Kernel $(uname -r) | $(uptime -p 2>/dev/null || true)"

# Support-Ende (Stand 10/2026; ESM/Extended Support ggf. gesondert prüfen)
case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:14.04|ubuntu:16.04|ubuntu:18.04|ubuntu:20.04|debian:9|debian:10|debian:11|centos:7*|centos:8*|rhel:7*)
        log_err "Betriebssystem ${PRETTY_NAME:-$ID $VERSION_ID} ist ohne regulären Support (EOL) — Migration planen"
        ;;
    *) log_ok "Betriebssystem-Version ${VERSION_ID:-?} nicht als EOL bekannt" ;;
esac

# Load
read -r LOAD1 LOAD5 LOAD15 _ </proc/loadavg
CPUS="$(nproc 2>/dev/null || echo 1)"
if awk -v l="$LOAD5" -v c="$CPUS" 'BEGIN { exit !(l > c) }'; then
    log_warn "Load (5 min) ${LOAD5} liegt über der CPU-Anzahl ${CPUS}"
else
    log_ok "Load ${LOAD1} / ${LOAD5} / ${LOAD15} bei ${CPUS} CPUs"
fi

# Arbeitsspeicher / Swap
MEM_AVAIL_PCT="$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{ if (t>0) printf "%d", a*100/t; else print 100 }' /proc/meminfo)"
SWAP_USED_PCT="$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{ if (t>0) printf "%d", (t-f)*100/t; else print 0 }' /proc/meminfo)"
if (( MEM_AVAIL_PCT < 10 )); then
    log_err "Nur noch ${MEM_AVAIL_PCT}% Arbeitsspeicher verfügbar"
elif (( MEM_AVAIL_PCT < 20 )); then
    log_warn "Nur noch ${MEM_AVAIL_PCT}% Arbeitsspeicher verfügbar"
else
    log_ok "Arbeitsspeicher: ${MEM_AVAIL_PCT}% verfügbar"
fi
(( SWAP_USED_PCT > 50 )) && log_warn "Swap zu ${SWAP_USED_PCT}% belegt — Java/Relution-Heap prüfen"
free -h 2>/dev/null | detail "Speicher"

# Dateisysteme (Belegung + Inodes)
DISK_ISSUES=0
check_df() {
    local what="$1" fs pct mnt p
    shift
    while read -r fs pct mnt; do
        p="${pct%\%}"
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        if (( p >= DISK_CRIT )); then
            log_err "${what} ${mnt} zu ${p}% belegt (${fs})"; DISK_ISSUES=$((DISK_ISSUES + 1))
        elif (( p >= DISK_WARN )); then
            log_warn "${what} ${mnt} zu ${p}% belegt (${fs})"; DISK_ISSUES=$((DISK_ISSUES + 1))
        fi
    done < <(df -P "$@" -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | awk 'NR>1 {print $1, $5, $6}')
}
check_df "Dateisystem"
check_df "Inodes auf" -i
(( DISK_ISSUES == 0 )) && log_ok "Alle Dateisysteme unter ${DISK_WARN}% (Platz und Inodes)"
df -hP -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | detail "Dateisysteme"

# Fehlgeschlagene systemd-Units
FAILED_UNITS="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' -)"
if [[ -n "$FAILED_UNITS" ]]; then
    log_err "Fehlgeschlagene Dienste: ${FAILED_UNITS}"
else
    log_ok "Keine fehlgeschlagenen systemd-Dienste"
fi

# Zeitsynchronisation (wichtig für Zertifikate, Push, DEP/ABM-Token)
NTP="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
if [[ -z "$NTP" ]]; then
    timedatectl 2>/dev/null | grep -qiE 'synchronized: yes' && NTP="yes" || NTP="no"
fi
if [[ "$NTP" == "yes" ]]; then
    log_ok "Systemzeit ist synchronisiert"
else
    log_warn "Systemzeit ist NICHT synchronisiert (chrony/timesyncd prüfen)"
fi

# Neustart erforderlich?
RUN_KERNEL="$(uname -r)"
NEWEST_KERNEL="$(find /boot -maxdepth 1 -name 'vmlinuz-*' ! -name '*rescue*' -printf '%f\n' 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -n 1)"
REBOOT_REASON=""
[[ -f /var/run/reboot-required ]] && REBOOT_REASON+=" reboot-required-Flag gesetzt;"
if [[ -n "$NEWEST_KERNEL" && "$NEWEST_KERNEL" != "$RUN_KERNEL" ]]; then
    REBOOT_REASON+=" neuerer Kernel ${NEWEST_KERNEL} installiert (läuft: ${RUN_KERNEL});"
fi
if has needs-restarting; then
    $SUDO needs-restarting -r &>/dev/null || REBOOT_REASON+=" needs-restarting meldet Neustartbedarf;"
fi
if [[ -n "$REBOOT_REASON" ]]; then
    log_warn "Neustart ausstehend:${REBOOT_REASON%;}"
else
    log_ok "Kein Neustart ausstehend"
fi

# ---------- Schritt 2: Patch-Stand ----------
log_step "Patch-Stand"

LAST_PATCH_EPOCH=""
case "$PKG" in
    apt)
        LAST_PATCH_STR="$($SUDO zcat -f /var/log/apt/history.log* 2>/dev/null \
            | awk '/^Start-Date:/ {d=$2" "$3} /^Upgrade:/ {print d}' | sort | tail -n 1)"
        [[ -n "$LAST_PATCH_STR" ]] && LAST_PATCH_EPOCH="$(date -d "$LAST_PATCH_STR" +%s 2>/dev/null)"
        $SUDO zcat -f /var/log/apt/history.log 2>/dev/null | grep -E '^(Start-Date|Commandline)' | tail -n 10 \
            | detail "Letzte apt-Vorgänge"
        if apt-config dump 2>/dev/null | grep -q 'APT::Periodic::Unattended-Upgrade "1"'; then
            log_info "Automatische Updates: unattended-upgrades aktiv"
        else
            log_info "Automatische Updates: nicht aktiv (manuelles Patchen)"
        fi
        ;;
    dnf)
        # Neuester history-Eintrag mit Upgrade-Aktion (U); Liste ist absteigend sortiert
        LAST_PATCH_STR="$($SUDO "$DNF" -q history list 2>/dev/null \
            | awk -F'|' 'NR>1 && $4 ~ /U/ { gsub(/^ +| +$/, "", $3); print $3; exit }')"
        [[ -n "$LAST_PATCH_STR" ]] && LAST_PATCH_EPOCH="$(date -d "$LAST_PATCH_STR" +%s 2>/dev/null)"
        $SUDO "$DNF" -q history list 2>/dev/null | head -n 12 | detail "Letzte dnf-Vorgänge"
        if systemctl is-enabled dnf-automatic.timer dnf-automatic-install.timer 2>/dev/null | grep -q enabled; then
            log_info "Automatische Updates: dnf-automatic aktiv"
        else
            log_info "Automatische Updates: nicht aktiv (manuelles Patchen)"
        fi
        ;;
esac

if [[ -n "$LAST_PATCH_EPOCH" ]]; then
    PATCH_AGE_D=$(( (NOW - LAST_PATCH_EPOCH) / 86400 ))
    PATCH_DATE="$(date -d "@${LAST_PATCH_EPOCH}" '+%d.%m.%Y')"
    if (( PATCH_AGE_D >= PATCH_CRIT_DAYS )); then
        log_err "Letztes Update am ${PATCH_DATE} (vor ${PATCH_AGE_D} Tagen)"
    elif (( PATCH_AGE_D >= PATCH_WARN_DAYS )); then
        log_warn "Letztes Update am ${PATCH_DATE} (vor ${PATCH_AGE_D} Tagen)"
    else
        log_ok "Letztes Update am ${PATCH_DATE} (vor ${PATCH_AGE_D} Tagen)"
    fi
else
    log_warn "Zeitpunkt des letzten Updates nicht ermittelbar (Paket-Historie leer oder rotiert)"
fi

# ---------- Schritt 3: Offene Updates ----------
log_step "Offene Updates"

UPD_COUNT=0
SEC_COUNT=0
case "$PKG" in
    apt)
        if (( REFRESH )); then
            if $SUDO apt-get update -qq >>"$REPORT" 2>&1; then
                log_ok "Paketlisten aktualisiert"
            else
                log_warn "apt-get update fehlgeschlagen — Ergebnis basiert auf alten Listen"
            fi
        else
            LISTS_EPOCH="$(find /var/lib/apt/lists -maxdepth 1 -type f -name '*Release' -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1)"
            LISTS_EPOCH="${LISTS_EPOCH%.*}"
            if [[ -n "$LISTS_EPOCH" ]]; then
                LISTS_AGE_D=$(( (NOW - LISTS_EPOCH) / 86400 ))
                (( LISTS_AGE_D > 2 )) && log_warn "Paketlisten sind ${LISTS_AGE_D} Tage alt — mit --refresh ausführen für belastbares Ergebnis"
            fi
        fi
        UPD_LIST="$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | awk '/^Inst / {print $2, $3, $4, $5, $6}')"
        UPD_COUNT="$(grep -c . <<<"$UPD_LIST")"
        SEC_COUNT="$(grep -ci 'security' <<<"$UPD_LIST")"
        HELD="$(apt-mark showhold 2>/dev/null | paste -sd' ' -)"
        [[ -n "$HELD" ]] && log_warn "Zurückgehaltene Pakete (apt-mark hold): ${HELD}"
        ;;
    dnf)
        if (( REFRESH )); then
            if $SUDO "$DNF" -q makecache >>"$REPORT" 2>&1; then
                log_ok "Paket-Metadaten aktualisiert"
            else
                log_warn "makecache fehlgeschlagen — Ergebnis evtl. unvollständig"
            fi
        fi
        UPD_LIST="$($SUDO "$DNF" -q check-update 2>/dev/null | awk 'NF==3 && $1 ~ /\./')"
        UPD_COUNT="$(grep -c . <<<"$UPD_LIST")"
        SEC_COUNT="$($SUDO "$DNF" -q updateinfo list --security 2>/dev/null | awk 'NF>=3 {print $3}' | sort -u | grep -c .)"
        ;;
    *)
        UPD_LIST=""
        log_warn "Unbekannte Paketverwaltung — Update-Prüfung übersprungen"
        ;;
esac

if (( SEC_COUNT > 0 )); then
    log_err "${SEC_COUNT} Sicherheitsupdate(s) offen (gesamt ${UPD_COUNT})"
elif (( UPD_COUNT > 0 )); then
    log_warn "${UPD_COUNT} Update(s) offen, keine davon als Sicherheitsupdate markiert"
elif [[ "$PKG" != "unbekannt" ]]; then
    log_ok "Keine offenen Updates"
fi
[[ -n "$UPD_LIST" ]] && detail "Offene Updates" <<<"$UPD_LIST"

# ---------- Schritt 4: Relution-Installation & Dienste ----------
log_step "Relution-Installation & Dienste"

HAS_DOCKER=0
if has docker && $SUDO docker info &>/dev/null; then
    HAS_DOCKER=1
fi

RELUTION_CTRS=""
if (( HAS_DOCKER )); then
    RELUTION_CTRS="$($SUDO docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null \
        | awk 'tolower($2) ~ /relution/ || tolower($1) ~ /^relution$/ {print $1}' | sort -u)"
fi
NATIVE_UNITS="$(systemctl list-unit-files --no-legend --type=service 2>/dev/null | awk 'tolower($1) ~ /relution/ {print $1}')"
NATIVE_PKG_VER=""
case "$PKG" in
    apt) NATIVE_PKG_VER="$(dpkg-query -W -f='${Version}' relution 2>/dev/null)" ;;
    dnf) rpm -q relution &>/dev/null && NATIVE_PKG_VER="$(rpm -q --qf '%{VERSION}-%{RELEASE}' relution)" ;;
esac

if [[ -n "$RELUTION_CTRS" && ( -n "$NATIVE_UNITS" || -n "$NATIVE_PKG_VER" ) ]]; then
    MODE="docker+nativ"
    log_warn "Relution als Container UND als nativer Dienst gefunden — Doppelinstallation prüfen"
elif [[ -n "$RELUTION_CTRS" ]]; then
    MODE="docker"
    log_ok "Betriebsart: Docker (Container: $(paste -sd' ' - <<<"$RELUTION_CTRS"))"
elif [[ -n "$NATIVE_UNITS" || -n "$NATIVE_PKG_VER" ]]; then
    MODE="nativ"
    log_ok "Betriebsart: native Installation${NATIVE_PKG_VER:+ (Paket relution ${NATIVE_PKG_VER})}"
else
    MODE="nicht-gefunden"
    log_err "Keine Relution-Installation erkannt (weder Container noch Dienst/Paket)"
fi

# --- Docker ---
if (( HAS_DOCKER )); then
    log_info "Docker Engine $($SUDO docker version --format '{{.Server.Version}}' 2>/dev/null)"
    $SUDO docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | detail "Container"
    $SUDO docker compose ls 2>/dev/null | detail "Compose-Projekte"
    $SUDO docker system df 2>/dev/null | detail "Docker-Speicher"

    mapfile -t CTR_IDS < <($SUDO docker ps -aq 2>/dev/null)
    if (( ${#CTR_IDS[@]} > 0 )); then
        # Volumes/Bind-Mounts: zeigt, welche Daten ins Backup gehören
        $SUDO docker inspect -f '{{.Name}}{{range .Mounts}} | {{.Source}} -> {{.Destination}}{{end}}' "${CTR_IDS[@]}" 2>/dev/null \
            | detail "Persistente Daten der Container (müssen im Backup sein)"

        while read -r name status health restarts policy image; do
            name="${name#/}"
            is_relution=0
            grep -qx "$name" <<<"$RELUTION_CTRS" && is_relution=1
            problem=0
            if [[ "$status" != "running" ]]; then
                problem=1
                if (( is_relution )); then log_err "Relution-Container ${name} ist ${status}"
                else log_warn "Container ${name} (${image}) ist ${status}"; fi
            fi
            if [[ "$health" == "unhealthy" ]]; then
                problem=1; log_err "Container ${name} meldet unhealthy"
            elif [[ "$health" == "starting" ]]; then
                problem=1; log_warn "Container ${name} ist noch im Health-Status starting"
            fi
            if (( restarts > 5 )); then
                problem=1; log_warn "Container ${name} wurde ${restarts}x neu gestartet (Crash-Loop?)"
            fi
            if [[ "$status" == "running" && "$policy" == "no" ]]; then
                problem=1; log_warn "Container ${name} hat keine Restart-Policy — startet nach Reboot nicht"
            fi
            if (( problem == 0 )); then
                if [[ "$health" == "-" ]]; then
                    log_ok "Container ${name}: ${status} (${image}, kein Healthcheck definiert)"
                else
                    log_ok "Container ${name}: ${status}, health ${health} (${image})"
                fi
            fi

            if (( is_relution )); then
                created="$($SUDO docker image inspect -f '{{.Created}}' "$image" 2>/dev/null)"
                if [[ -n "$created" ]]; then
                    img_age_d=$(( (NOW - $(date -d "$created" +%s 2>/dev/null || echo "$NOW")) / 86400 ))
                    if (( img_age_d > IMAGE_WARN_DAYS )); then
                        log_warn "Relution-Image ${image} ist ${img_age_d} Tage alt — Relution-Update prüfen"
                    else
                        log_info "Relution-Image ${image}, gebaut vor ${img_age_d} Tagen"
                    fi
                fi
                [[ "$image" == *:latest || "$image" != *:* ]] && log_info "Image-Tag nicht gepinnt (${image}) — Version nicht reproduzierbar"
            fi
        done < <($SUDO docker inspect -f '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} {{.RestartCount}} {{or .HostConfig.RestartPolicy.Name "no"}} {{.Config.Image}}' "${CTR_IDS[@]}" 2>/dev/null)
    fi
elif has docker; then
    log_warn "Docker installiert, aber Daemon nicht erreichbar"
fi

# --- Native Dienste (Relution + typische Begleitdienste) ---
for unit in $NATIVE_UNITS mariadb.service mysql.service mysqld.service nginx.service minio.service traefik.service; do
    unit_exists "$unit" || continue
    if systemctl is-active --quiet "$unit"; then
        if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            log_ok "Dienst ${unit} läuft und ist aktiviert"
        else
            log_warn "Dienst ${unit} läuft, ist aber nicht für den Systemstart aktiviert"
        fi
    else
        log_err "Dienst ${unit} läuft NICHT"
    fi
done
if [[ "$MODE" == nativ* || "$MODE" == *nativ ]] && has java; then
    log_info "Java: $(java -version 2>&1 | head -n 1)"
fi

# --- Ports ---
ss -tlnp 2>/dev/null | detail "Lauschende TCP-Ports"
if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ':443$'; then
    log_ok "Port 443 lauscht"
else
    log_warn "Auf Port 443 lauscht nichts — Reverse Proxy prüfen"
fi

# --- HTTP-Erreichbarkeit ---
if has curl; then
    read -r HTTP_CODE HTTP_TIME < <(curl -sk -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 15 \
        "${RELUTION_URL}${RELUTION_HEALTH_PATH}" 2>/dev/null || echo "000 0")
    if [[ "${HTTP_CODE:-000}" =~ ^[23] ]]; then
        log_ok "${RELUTION_URL}${RELUTION_HEALTH_PATH} antwortet mit HTTP ${HTTP_CODE} in ${HTTP_TIME}s"
    else
        log_err "${RELUTION_URL}${RELUTION_HEALTH_PATH} nicht erreichbar (HTTP ${HTTP_CODE:-000}) — RELUTION_URL korrekt?"
    fi
else
    log_warn "curl fehlt — HTTP-Prüfung übersprungen"
fi

# --- Zertifikat ---
CERT_HOST="${RELUTION_URL#*://}"
CERT_HOST="${CERT_HOST%%/*}"
CERT_PORT=443
if [[ "$CERT_HOST" == *:* ]]; then
    CERT_PORT="${CERT_HOST##*:}"
    CERT_HOST="${CERT_HOST%%:*}"
fi
if has openssl; then
    CERT_PEM="$(echo | timeout 10 openssl s_client -connect "${CERT_HOST}:${CERT_PORT}" -servername "$CERT_HOST" 2>/dev/null)"
    CERT_END="$(openssl x509 -noout -enddate <<<"$CERT_PEM" 2>/dev/null | cut -d= -f2)"
    if [[ -n "$CERT_END" ]]; then
        CERT_DAYS=$(( ($(date -d "$CERT_END" +%s) - NOW) / 86400 ))
        openssl x509 -noout -subject -issuer -enddate <<<"$CERT_PEM" 2>/dev/null | detail "Zertifikat ${CERT_HOST}"
        if (( CERT_DAYS < CERT_CRIT_DAYS )); then
            log_err "Zertifikat ${CERT_HOST} läuft in ${CERT_DAYS} Tagen ab"
        elif (( CERT_DAYS < CERT_WARN_DAYS )); then
            log_warn "Zertifikat ${CERT_HOST} läuft in ${CERT_DAYS} Tagen ab"
        else
            log_ok "Zertifikat ${CERT_HOST} gültig noch ${CERT_DAYS} Tage"
        fi
    else
        log_warn "Zertifikat von ${CERT_HOST}:${CERT_PORT} nicht abrufbar"
    fi
fi

# ---------- Schritt 5: Cronjobs & Timer ----------
log_step "Cronjobs & systemd-Timer"

CRON_ALL=""
add_cron() {
    local src="$1" line
    while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# || "$line" =~ ^[A-Za-z_]+= ]] && continue
        CRON_ALL+="${src}: ${line}"$'\n'
    done
}

[[ -r /etc/crontab ]] && add_cron "/etc/crontab" < <($SUDO cat /etc/crontab 2>/dev/null)
for f in /etc/cron.d/*; do
    [[ -f "$f" ]] && add_cron "$f" < <($SUDO cat "$f" 2>/dev/null)
done
while IFS= read -r user; do
    add_cron "crontab(${user})" < <($SUDO crontab -l -u "$user" 2>/dev/null)
done < <(getent passwd | cut -d: -f1)
for period in hourly daily weekly monthly; do
    [[ -d "/etc/cron.${period}" ]] || continue
    add_cron "cron.${period}" < <(find "/etc/cron.${period}" -maxdepth 1 -type f ! -name '.placeholder' -printf '%f\n' 2>/dev/null)
done

CRON_COUNT="$(grep -c . <<<"$CRON_ALL")"
log_info "${CRON_COUNT} Cron-Einträge gefunden (vollständige Liste im Report)"
[[ -n "$CRON_ALL" ]] && detail "Cronjobs" <<<"$CRON_ALL"

# Cron-Daemon
CRON_DAEMON_OK=0
for c in cron.service crond.service; do
    unit_exists "$c" || continue
    if systemctl is-active --quiet "$c"; then CRON_DAEMON_OK=1; fi
done
if (( CRON_DAEMON_OK )); then
    log_ok "Cron-Dienst läuft"
else
    log_err "Cron-Dienst läuft nicht — geplante Jobs (inkl. Backups) werden nicht ausgeführt"
fi

# Systemd-Timer
TIMERS="$(systemctl list-timers --all --no-pager 2>/dev/null)"
[[ -n "$TIMERS" ]] && detail "systemd-Timer" <<<"$TIMERS"

# Backup-relevante Jobs
BACKUP_JOBS="$( { grep -Ei "$BACKUP_KEYWORDS" <<<"$CRON_ALL"; grep -Ei "$BACKUP_KEYWORDS" <<<"$TIMERS"; } | grep -v '^$')"
BACKUP_JOB_COUNT="$(grep -c . <<<"$BACKUP_JOBS")"
if (( BACKUP_JOB_COUNT > 0 )); then
    log_ok "${BACKUP_JOB_COUNT} Backup-bezogene Jobs gefunden:"
    while IFS= read -r job; do log_info "  ${job:0:140}"; done <<<"$BACKUP_JOBS"
else
    log_err "Kein Backup-Job in Cron oder systemd-Timern gefunden"
fi

# Verweisen Backup-Jobs auf Skripte, die es nicht (mehr) gibt?
while IFS= read -r script; do
    [[ -z "$script" ]] && continue
    $SUDO test -e "$script" || log_err "Backup-Job verweist auf fehlende Datei: ${script}"
done < <(grep -oE "/[^[:space:];|&>\"']+\.(sh|py|pl)" <<<"$BACKUP_JOBS" | sort -u)

# ---------- Schritt 6: Backups ----------
log_step "Backups"

TOOLS_FOUND=""
for t in restic borg rsnapshot mariabackup mysqldump mariadb-dump duplicity rclone; do
    has "$t" && TOOLS_FOUND+="${t} "
done
log_info "Backup-Werkzeuge installiert: ${TOOLS_FOUND:-keine}"
if [[ "$TOOLS_FOUND" =~ (restic|borg) ]]; then
    log_info "restic/borg erkannt — Repository-Stand wird nicht geprüft (Zugangsdaten nötig, ggf. ergänzen)"
fi

ROOT_DEV="$(df -P / | awk 'NR==2 {print $1}')"
RECENT_FILES=""
DIRS_FOUND=0
for d in $BACKUP_DIRS; do
    $SUDO test -d "$d" || continue
    DIRS_FOUND=$((DIRS_FOUND + 1))

    mapfile -t BK < <($SUDO find "$d" -type f -regextype posix-extended -iregex "$BACKUP_FILE_REGEX" \
                      -printf '%T@ %s %p\n' 2>/dev/null | sort -n)
    if (( ${#BK[@]} == 0 )); then
        log_err "Backup-Verzeichnis ${d} existiert, enthält aber keine Backup-Dateien"
        continue
    fi

    read -r MT SZ NEWEST <<<"${BK[-1]}"
    MT="${MT%.*}"
    AGE_H=$(( (NOW - MT) / 3600 ))
    TOTAL_SZ=0
    for entry in "${BK[@]}"; do
        read -r _ s _ <<<"$entry"
        TOTAL_SZ=$((TOTAL_SZ + s))
    done

    if (( AGE_H > BACKUP_MAX_AGE_H )); then
        log_err "${d}: neuestes Backup ist ${AGE_H} h alt (Grenze ${BACKUP_MAX_AGE_H} h) — $(basename "$NEWEST")"
    else
        log_ok "${d}: neuestes Backup ${AGE_H} h alt, $(human "$SZ") — $(basename "$NEWEST")"
    fi
    log_info "${d}: ${#BK[@]} Dateien, gesamt $(human "$TOTAL_SZ")"

    (( SZ < BACKUP_MIN_SIZE_KB * 1024 )) && log_warn "${d}: neuestes Backup nur $(human "$SZ") — unvollständig?"

    # Deutlicher Größeneinbruch gegenüber dem Vorgänger
    if (( ${#BK[@]} >= 2 )); then
        read -r _ PREV_SZ _ <<<"${BK[-2]}"
        if (( PREV_SZ > 0 && SZ * 2 < PREV_SZ )); then
            log_warn "${d}: neuestes Backup ($(human "$SZ")) ist weniger als halb so groß wie das vorherige ($(human "$PREV_SZ"))"
        fi
    fi

    # Archiv-Integrität
    if (( BACKUP_VERIFY )); then
        verify_cmd=()
        case "$NEWEST" in
            *.gz|*.tgz) verify_cmd=(gzip -t) ;;
            *.zst)      has zstd  && verify_cmd=(zstd -t -q) ;;
            *.xz)       verify_cmd=(xz -t) ;;
            *.bz2)      verify_cmd=(bzip2 -t) ;;
        esac
        if (( ${#verify_cmd[@]} > 0 )); then
            if $SUDO "${verify_cmd[@]}" "$NEWEST" &>/dev/null; then
                log_ok "${d}: Archiv-Integrität des neuesten Backups OK"
            else
                log_err "${d}: neuestes Backup ist BESCHÄDIGT ($(basename "$NEWEST"))"
            fi
        fi
    fi

    # Liegt das Backup nur lokal auf der Systemplatte?
    BK_DEV="$(df -P "$d" 2>/dev/null | awk 'NR==2 {print $1}')"
    if [[ "$BK_DEV" == "$ROOT_DEV" ]]; then
        log_warn "${d} liegt auf demselben Dateisystem wie / — nur lokale Kopie erkennbar (Offsite-Kopie prüfen)"
    fi

    START=$(( ${#BK[@]} > 10 ? ${#BK[@]} - 10 : 0 ))
    printf '%s\n' "${BK[@]:START}" | while read -r m s p; do
        printf '%s  %10s  %s\n' "$(date -d "@${m%.*}" '+%Y-%m-%d %H:%M')" "$(human "$s")" "$p"
    done | detail "Neueste Backup-Dateien in ${d}"

    RECENT_FILES+="$($SUDO find "$d" -type f -regextype posix-extended -iregex "$BACKUP_FILE_REGEX" \
                     -mmin -$((BACKUP_MAX_AGE_H * 60)) 2>/dev/null)"$'\n'
done

if (( DIRS_FOUND == 0 )); then
    if (( BACKUP_JOB_COUNT == 0 )); then
        log_err "Kein Backup-Mechanismus erkennbar: weder Backup-Job noch Backup-Verzeichnis"
    else
        log_warn "Keines der Backup-Verzeichnisse existiert (BACKUP_DIRS anpassen): ${BACKUP_DIRS}"
    fi
fi

# Erwartete Bestandteile: gibt es für jeden ein aktuelles Backup?
IFS=';' read -ra EXPECTS <<<"$BACKUP_EXPECT"
for e in "${EXPECTS[@]}"; do
    pat="${e%%=*}"
    label="${e#*=}"
    [[ -z "$pat" ]] && continue
    if grep -qEi "$pat" <<<"$RECENT_FILES"; then
        log_ok "Aktuelles Backup vorhanden: ${label}"
    else
        log_err "FEHLENDES Backup (keins jünger als ${BACKUP_MAX_AGE_H} h): ${label}"
    fi
done
log_info "Nicht sichtbar für dieses Skript: Snapshots beim Hoster/Hypervisor — separat prüfen"

# ---------- Schritt 7: Zusammenfassung ----------
log_step "Zusammenfassung"

if (( CNT_CRIT > 0 )); then
    STATUS="KRITISCH"; RC=2; COLOR="$C_RED"
elif (( CNT_WARN > 0 )); then
    STATUS="WARNUNG";  RC=1; COLOR="$C_YELLOW"
else
    STATUS="OK";       RC=0; COLOR="$C_GREEN"
fi

say "  Host: ${HOST_SHORT} | OS: ${PRETTY_NAME:-?} | Relution: ${MODE}"
say "  Ergebnis: ${C_GREEN}${CNT_OK} OK${C_RESET}, ${C_YELLOW}${CNT_WARN} Warnungen${C_RESET}, ${C_RED}${CNT_CRIT} kritisch${C_RESET}"
if (( ${#FINDINGS[@]} > 0 )); then
    say "\n  Befunde:"
    for f in "${FINDINGS[@]}"; do say "    ${f}"; done
fi

# Maschinenlesbare Zeile für Sammelauswertung (grep AUDIT_RESULT *.log)
say "\nAUDIT_RESULT host=${HOST_SHORT} status=${STATUS} ok=${CNT_OK} warn=${CNT_WARN} crit=${CNT_CRIT} relution=${MODE} updates=${UPD_COUNT} security=${SEC_COUNT}"
say "\n${COLOR}${C_BOLD}Audit abgeschlossen: ${STATUS}${C_RESET} — Report: ${REPORT}"

# Alte Reports aufräumen
find "$REPORT_DIR" -maxdepth 1 -name 'audit_*.log' -mtime +"$REPORT_KEEP_DAYS" -delete 2>/dev/null

exit "$RC"
