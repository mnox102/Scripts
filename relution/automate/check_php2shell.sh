#!/usr/bin/env bash

# Prüft einen Linux-Host (z.B. Relution-App-Server) auf PHP-Installationen,
# die von php2shell (CVE-2026-109618, CVE-2026-109619) betroffen sein können.
# Rein lesend – es wird nichts installiert, gestoppt oder verändert.
# Quelle(n):
#   https://www.php.net/  (Security Advisory vom 21.10.2026, GHSA-w8hw-w9fx-j79w)
#   https://www.php.net/supported-versions.php
# Gepatchte Upstream-Versionen: 8.5.12, 8.4.27, 8.3.36, 8.2.35 (8.1 und älter: kein Upstream-Fix)
# Mit Statusanzeige und Fehlerprüfung nach jedem Schritt.
#
# Aufruf:          sudo bash check-php2shell.sh
# Mehrere Hosts:   for h in host1 host2; do echo "=== $h"; ssh "$h" 'sudo bash -s' < check-php2shell.sh; done
# Exit-Codes:      0 = kein Befund, 2 = Warnung (manuell prüfen), 3 = kritisch, 1 = Skriptfehler
# Getestet auf:    Ubuntu 24.04 (mit/ohne PHP 8.3, nginx + php-fpm), siehe Abgabe

set -uo pipefail   # bewusst ohne -e: Fehler werden explizit behandelt

# ---------- Farben / Formatierung ----------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly C_RESET='\033[0m'  C_BOLD='\033[1m'
    readonly C_GREEN='\033[0;32m' C_RED='\033[0;31m'
    readonly C_YELLOW='\033[0;33m' C_BLUE='\033[0;34m'
else
    readonly C_RESET='' C_BOLD='' C_GREEN='' C_RED='' C_YELLOW='' C_BLUE=''
fi

readonly SCRIPT_NAME="check-php2shell"   # fest, da $0 bei "bash -s" nur "bash" ist
readonly LOG_FILE="/tmp/${SCRIPT_NAME}.log"
readonly CVE_ID="CVE-2026-109618"

# Gepatchte Patch-Level je Minor-Version
declare -A FIXED=([8.2]=35 [8.3]=36 [8.4]=27 [8.5]=12)

STEP_NUM=0
TOTAL_STEPS=6   # bei jedem neuen log_step anpassen!

CRIT=()      # kritische Befunde
WARN=()      # manuell prüfen
EXPOSED=0    # PHP verarbeitet (wahrscheinlich) Webanfragen

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
    echo -e "\n${C_RED}${C_BOLD}Vorgang abgebrochen.${C_RESET} Log: ${LOG_FILE}"
    exit 1
}

# Schreibt Rohdaten mit Trenner ins Log
log_raw() {
    { echo "### $1"; cat; echo; } >>"$LOG_FILE"
}

# Gibt "gepatcht", "verwundbar", "eol", "neuer" oder "unbekannt" zurück
version_status() {
    local ver="$1" major minor patch mm fixed
    [[ "$ver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || { echo "unbekannt"; return; }
    major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"
    mm="${major}.${minor}"
    fixed="${FIXED[$mm]:-}"
    if [[ -n "$fixed" ]]; then
        if (( patch >= fixed )); then echo "gepatcht"; else echo "verwundbar"; fi
    elif (( major < 8 || (major == 8 && minor < 2) )); then
        echo "eol"
    else
        echo "neuer"
    fi
}

# Paketname zu einer Datei (rpm oder dpkg)
pkg_of() {
    local file="$1"
    if command -v rpm &>/dev/null && rpm -qf "$file" &>/dev/null; then
        rpm -qf "$file" --qf '%{NAME}\n' 2>/dev/null | head -n 1
    elif command -v dpkg &>/dev/null; then
        dpkg -S "$file" 2>/dev/null | head -n 1 | cut -d: -f1
    fi
}

# Hat der Distributor den Fix zurückportiert? (Changelog nennt die CVE)
has_backport() {
    local pkg="$1"
    [[ -n "$pkg" ]] || return 1
    if command -v rpm &>/dev/null && rpm -q "$pkg" &>/dev/null; then
        rpm -q --changelog "$pkg" 2>/dev/null | grep -q "$CVE_ID"
    elif [[ -f "/usr/share/doc/${pkg}/changelog.Debian.gz" ]]; then
        zgrep -q "$CVE_ID" "/usr/share/doc/${pkg}/changelog.Debian.gz" 2>/dev/null
    else
        return 1
    fi
}

# PHP-Version aus einem Binary lesen
php_version() {
    local bin="$1" out
    if [[ "$(basename "$bin")" == frankenphp* ]]; then
        out="$(timeout 5 "$bin" version 2>/dev/null | grep -oE 'PHP [0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -n 1)"
        echo "${out#PHP }"
    else
        timeout 5 "$bin" -v 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -n 1
    fi
}

# ---------- Vorprüfungen ----------
echo -e "${C_BOLD}php2shell-Prüfung (${CVE_ID} / CVE-2026-109619)${C_RESET}"

# Root nötig, sonst fehlen Prozessdetails, Sockets, Container und Teile der Webserver-Konfiguration
if [[ $EUID -ne 0 ]]; then
    log_err "Root-Rechte erforderlich. Aufruf: sudo bash ${SCRIPT_NAME}.sh"
    exit 1
fi
: > "$LOG_FILE"   # erst jetzt anlegen – als Nicht-root ggf. nicht beschreibbar

[[ -f /etc/os-release ]] || fail "/etc/os-release nicht gefunden – kein unterstütztes Linux."
# shellcheck disable=SC1091
. /etc/os-release
HOST="$(hostname -f 2>/dev/null || hostname)"
log_ok "Host: ${HOST}"
log_ok "System erkannt: ${PRETTY_NAME:-${ID:-unbekannt}}"

# ---------- Schritt 1: PHP-Installationen auf dem Host ----------
log_step "PHP-Installationen auf dem Host suchen"

declare -A SEEN=()
PHP_BINS=()
while IFS= read -r f; do
    real="$(readlink -f "$f" 2>/dev/null)" || continue
    [[ -x "$real" && -z "${SEEN[$real]:-}" ]] || continue
    SEEN[$real]=1
    PHP_BINS+=("$real")
done < <(find /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin /opt /usr/local/lsws \
            -maxdepth 7 -regextype posix-extended \( -type f -o -type l \) \
            -regex '.*/(php|php-fpm|php-cgi|lsphp|frankenphp)[0-9.]*' 2>/dev/null)

if (( ${#PHP_BINS[@]} == 0 )); then
    log_ok "Keine PHP-Binaries gefunden"
else
    for b in "${PHP_BINS[@]}"; do
        log_warn "PHP-Binary: ${b}"
    done
fi

if command -v rpm &>/dev/null && rpm -qa &>/dev/null && [[ "$(rpm -qa | wc -l)" -gt 0 ]]; then
    PKGS="$(rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' | grep -iE '^(php|lsphp|frankenphp)' | sort)"
else
    PKGS="$(dpkg-query -W -f='${Package} ${Version} ${db:Status-Status}\n' 2>/dev/null \
            | awk '$3=="installed"' | grep -iE '^(php|libapache2-mod-php|lsphp|frankenphp)' | sort)"
fi
echo "$PKGS" | log_raw "Installierte PHP-Pakete"
PKG_COUNT="$(grep -c . <<<"$PKGS")"
if (( PKG_COUNT == 0 )); then
    log_ok "Keine PHP-Pakete installiert"
else
    log_warn "${PKG_COUNT} PHP-Pakete installiert (Liste im Log)"
fi

# ---------- Schritt 2: Laufende PHP-Prozesse, Dienste, Module ----------
log_step "Laufende PHP-Prozesse, Dienste und Webserver-Module prüfen"

PROCS="$(ps -eo pid=,user=,comm=,args= | awk '$3 ~ /^(php|lsphp|frankenphp)/')"
echo "$PROCS" | log_raw "PHP-Prozesse"
if [[ -n "$PROCS" ]]; then
    EXPOSED=1
    while read -r comm cnt; do
        log_warn "Prozess läuft: ${comm} (${cnt}x)"
    done < <(awk '{print $3}' <<<"$PROCS" | sort | uniq -c | awk '{print $2, $1}')
else
    log_ok "Keine PHP-Prozesse aktiv"
fi

if command -v systemctl &>/dev/null; then
    UNITS="$(systemctl list-units --type=service --all --no-legend --plain \
             '*php*' 'lsws*' 'frankenphp*' 2>/dev/null | awk '{print $1, $3, $4}')"
    echo "$UNITS" | log_raw "systemd-Units"
    if [[ -n "$UNITS" ]]; then
        while read -r unit load active; do
            [[ -n "$unit" ]] && log_warn "Dienst: ${unit} (${load}/${active})"
        done <<<"$UNITS"
    else
        log_ok "Keine PHP-Dienste in systemd"
    fi
fi

MODPHP="$(grep -rhEi '^[[:space:]]*LoadModule[[:space:]]+php' /etc/httpd /etc/apache2 2>/dev/null)"
if [[ -n "$MODPHP" ]]; then
    echo "$MODPHP" | log_raw "Apache mod_php"
    if pgrep -x 'httpd|apache2' &>/dev/null; then
        EXPOSED=1
        log_err "Apache mit mod_php aktiv (höchstes Risiko laut php.net)"
    else
        log_warn "mod_php konfiguriert, Apache läuft aber nicht"
    fi
else
    log_ok "Kein mod_php konfiguriert"
fi

ss -xlpn 2>/dev/null | grep -iE 'php|lsphp' | log_raw "PHP-Sockets (Unix)"
ss -tlpn 2>/dev/null | grep -iE 'php|lsphp|frankenphp' | log_raw "PHP-Ports (TCP)"

# ---------- Schritt 3: Webserver-Konfiguration ----------
log_step "Webserver-Konfiguration auf PHP-Weiterleitung prüfen"

CONF_DIRS=()
for d in /etc/nginx /etc/httpd /etc/apache2 /etc/caddy /etc/lighttpd /usr/local/lsws/conf; do
    [[ -d "$d" ]] && CONF_DIRS+=("$d")
done

if (( ${#CONF_DIRS[@]} == 0 )); then
    log_ok "Keine Webserver-Konfiguration gefunden"
else
    log_ok "Geprüft: ${CONF_DIRS[*]}"
    # Nur aktive Konfiguration: mitgelieferte Snippets und *-available-Verzeichnisse
    # sind nicht wirksam (Include aktiver Snippets wird über "fastcgi-php" erkannt)
    HITS="$(grep -REnI '(fastcgi_pass|fastcgi-php|php_fastcgi|php-fpm|\.php|(Set|Add)Handler.*php|AddType.*php)' \
            "${CONF_DIRS[@]}" 2>/dev/null \
            | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
            | grep -vE '^[^:]*/(snippets|sites-available|conf-available|mods-available)/')"
    echo "$HITS" | log_raw "PHP-Treffer in Webserver-Konfiguration"
    if [[ -n "$HITS" ]]; then
        EXPOSED=1
        log_err "Webserver leitet Anfragen an PHP weiter:"
        head -n 10 <<<"$HITS" | sed 's/^/    /'
        (( $(wc -l <<<"$HITS") > 10 )) && echo "    … weitere Treffer im Log"
        if (( ${#PHP_BINS[@]} == 0 )); then
            WARN+=("Webserver-Konfiguration verweist auf PHP, aber lokal kein PHP gefunden – Backend-Host (fastcgi_pass/proxy) prüfen")
        fi
    else
        log_ok "Keine PHP-Weiterleitung in der Webserver-Konfiguration"
    fi
fi

PHPFILES="$(find /var/www /srv /usr/share/nginx /usr/share/phpMyAdmin /usr/share/phpmyadmin \
            -maxdepth 4 -type f -name '*.php' 2>/dev/null)"
echo "$PHPFILES" | log_raw "PHP-Dateien in Webroots"
if [[ -n "$PHPFILES" ]]; then
    log_warn "$(grep -c . <<<"$PHPFILES") .php-Dateien in Webroots (Liste im Log)"
else
    log_ok "Keine .php-Dateien in üblichen Webroots"
fi

# ---------- Schritt 4: Container ----------
log_step "Container auf PHP prüfen"

RT_FOUND=0
for rt in docker podman; do
    command -v "$rt" &>/dev/null || continue
    RT_FOUND=1
    if ! CONTAINERS="$("$rt" ps --format '{{.ID}} {{.Names}} {{.Image}}' 2>>"$LOG_FILE")"; then
        log_warn "${rt}: Daemon nicht erreichbar – Container nicht geprüft"
        WARN+=("${rt}-Container konnten nicht geprüft werden")
        continue
    fi
    if [[ -z "$CONTAINERS" ]]; then
        log_ok "${rt}: keine laufenden Container"
        continue
    fi
    while read -r cid cname cimage; do
        cver="$(timeout 10 "$rt" exec "$cid" sh -c \
            'php -r "echo PHP_VERSION;" 2>/dev/null || php-fpm -v 2>/dev/null | head -n 1' 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
        if [[ -z "$cver" ]]; then
            log_ok "${cname} (${cimage}): kein PHP"
            continue
        fi
        cstat="$(version_status "$cver")"
        case "$cstat" in
            gepatcht|neuer)
                log_ok "${cname} (${cimage}): PHP ${cver} – gepatcht" ;;
            *)
                log_err "${cname} (${cimage}): PHP ${cver} – ${cstat}"
                CRIT+=("Container ${cname} (${cimage}): PHP ${cver} ${cstat} – Image aktualisieren, Distro-Backport im Image ggf. manuell prüfen") ;;
        esac
    done <<<"$CONTAINERS"
done
(( RT_FOUND )) || log_ok "Keine Container-Runtime (docker/podman) installiert"

# ---------- Schritt 5: Versionen bewerten ----------
log_step "PHP-Versionen auf dem Host bewerten"

if (( ${#PHP_BINS[@]} == 0 )); then
    log_ok "Nichts zu bewerten"
else
    for b in "${PHP_BINS[@]}"; do
        ver="$(php_version "$b")"
        stat="$(version_status "${ver:-x}")"
        pkg="$(pkg_of "$b")"
        if [[ "$stat" == "verwundbar" || "$stat" == "eol" ]] && has_backport "$pkg"; then
            stat="gepatcht (Distro-Backport in ${pkg})"
        fi
        case "$stat" in
            gepatcht*|neuer)
                log_ok "${b}: ${ver} – ${stat}" ;;
            unbekannt)
                log_warn "${b}: Version nicht lesbar"
                WARN+=("${b}: Version nicht ermittelbar – manuell prüfen") ;;
            *)
                if (( EXPOSED )); then
                    log_err "${b}: ${ver} – ${stat}, verarbeitet Webanfragen"
                    CRIT+=("${b}: PHP ${ver} ${stat} und webexponiert – sofort patchen oder Dienst stoppen")
                else
                    log_warn "${b}: ${ver} – ${stat}, aktuell nicht webexponiert"
                    WARN+=("${b}: PHP ${ver} ${stat}, nicht webexponiert – trotzdem patchen oder deinstallieren")
                fi ;;
        esac
    done
fi

# ---------- Schritt 6: Zusammenfassung ----------
log_step "Zusammenfassung für ${HOST}"

if (( ${#CRIT[@]} > 0 )); then
    for m in "${CRIT[@]}"; do log_err "$m"; done
    for m in "${WARN[@]}"; do log_warn "$m"; done
    echo -e "\n${C_RED}${C_BOLD}ERGEBNIS: KRITISCH – Host ist für php2shell angreifbar.${C_RESET} Details: ${LOG_FILE}"
    exit 3
elif (( ${#WARN[@]} > 0 )); then
    for m in "${WARN[@]}"; do log_warn "$m"; done
    echo -e "\n${C_YELLOW}${C_BOLD}ERGEBNIS: PRÜFEN – keine direkte Angreifbarkeit erkannt, aber offene Punkte.${C_RESET} Details: ${LOG_FILE}"
    exit 2
else
    log_ok "Kein verwundbares, webexponiertes PHP gefunden"
    echo -e "\n${C_GREEN}${C_BOLD}ERGEBNIS: NICHT BETROFFEN – Prüfung erfolgreich abgeschlossen!${C_RESET}"
    exit 0
fi
