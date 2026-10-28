#!/usr/bin/env bash

# Prüfskript für das Monitoring-/SIEM-Setup (Konzept v2, WireGuard-Hub auf grafana-mdm).
# Erkennt die Rolle des Servers (grafana-mdm, Wazuh-Server, Relution Docker/nativ),
# prüft zusätzlich den Härtungsstand (offene Ports, SSH, Updates, Dateirechte, Images),
# zeigt Systemdaten und Patchstand, listet alle Konfigurationen zu WireGuard,
# Firewall, Grafana/Prometheus und Wazuh und nennt die nächsten Schritte.
# Ändert nichts am System. Schlüssel und Passwörter werden nie ausgegeben.
# Quelle(n):
#   https://www.wireguard.com/quickstart/
#   https://grafana.com/docs/grafana/latest/administration/provisioning/
#   https://prometheus.io/docs/prometheus/latest/configuration/https/
#   https://documentation.wazuh.com/current/installation-guide/
# Mit Statusanzeige und Fehlerprüfung nach jedem Schritt.
# Getestet: Syntax (bash -n) und shellcheck; Ablauf nur auf einem Testsystem ohne
# Grafana/Relution/Wazuh. Auf den Zielservern noch nicht ausgeführt.

# shellcheck disable=SC2015,SC2016  # log_ok/log_warn liefern immer 0; awk-/grep-Ausdrücke bewusst in einfachen Anführungszeichen
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
readonly LOG_FILE="/tmp/${SCRIPT_NAME}.log"
: >> "$LOG_FILE"

readonly WG_CONF="/etc/wireguard/wg0.conf"
readonly HUB_IP="10.66.0.1"
readonly TUNNEL_NET="10.66.0.0/24"

STEP_NUM=0
TOTAL_STEPS=7   # bei jedem neuen log_step anpassen!

ROLE="unbekannt"
RELUTION_MODE=""
RELUTION_CTR=""
PROM_CTR=""
TUNNEL_IP=""
declare -a TODO=()

# ---------- Ausgabe-Funktionen ----------
log_step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo -e "\n${C_BOLD}${C_BLUE}[${STEP_NUM}/${TOTAL_STEPS}]${C_RESET} ${C_BOLD}$1${C_RESET}"
}

log_ok()   { echo -e "  ${C_GREEN}✔${C_RESET} $1"; }
log_err()  { echo -e "  ${C_RED}✘${C_RESET} $1"; }
log_warn() { echo -e "  ${C_YELLOW}⚠${C_RESET} $1"; }
log_info() { echo -e "    $1"; }

fail() {
    log_err "$1"
    echo -e "\n${C_RED}${C_BOLD}Vorgang abgebrochen.${C_RESET} Log: ${LOG_FILE}"
    exit 1
}

# Führt einen Befehl aus, hängt die Ausgabe ans Log an und bricht bei Fehler ab
# (Teil des Hausstil-Gerüsts; dieses Prüfskript ändert nichts und nutzt run() daher nicht)
# shellcheck disable=SC2329
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

# Ja/Nein-Abfrage; ohne Terminal (z.B. curl | bash) gilt der Default
# shellcheck disable=SC2329
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

# Merkt einen offenen Punkt für die Zusammenfassung
todo() { TODO+=("$1"); }

# ---------- Prüf-Hilfsfunktionen (nur lesend) ----------

# Gibt "active", "inactive", "failed" … oder "nicht installiert" zurück
svc_state() {
    local unit="$1"
    if systemctl cat "$unit" &>/dev/null; then
        systemctl is-active "$unit" 2>/dev/null || true
    else
        echo "nicht installiert"
    fi
}

# Dienststatus mit Bewertung ausgeben; Rückgabe 0 nur bei "active"
report_svc() {
    local name="$1" unit="$2" state restarts
    state="$(svc_state "$unit")"
    case "$state" in
        active)
            restarts="$(systemctl show "$unit" -p NRestarts --value 2>/dev/null || echo 0)"
            if [[ "${restarts:-0}" =~ ^[0-9]+$ && "${restarts:-0}" -gt 0 ]]; then
                log_warn "${name}: aktiv, aber ${restarts} automatische Neustarts (Absturzschleife?)"
                todo "${name}: Neustarts prüfen mit 'journalctl -u ${unit} -n 50'"
            else
                log_ok "${name}: aktiv"
            fi
            return 0 ;;
        "nicht installiert")
            log_warn "${name}: nicht installiert"
            return 1 ;;
        *)
            log_err "${name}: ${state}"
            todo "${name} starten bzw. Fehler prüfen: 'journalctl -u ${unit} -n 50'"
            return 1 ;;
    esac
}

# Lokale Adressen, auf denen ein TCP-Port lauscht (leer = lauscht nicht)
listen_addr() {
    ss -tlnH "sport = :$1" 2>/dev/null | awk '{print $4}' | sort -u | paste -sd' ' -
}

# Rechte und Besitzer einer Datei
perm_of() { $SUDO stat -c '%A %U:%G' "$1" 2>/dev/null || echo "?"; }

# Darf der Benutzer grafana die Datei lesen?
grafana_can_read() {
    if [[ -z "$SUDO" ]]; then
        runuser -u grafana -- test -r "$1" 2>/dev/null
    else
        sudo -u grafana test -r "$1" 2>/dev/null
    fi
}

# HTTP-Statuscode einer URL (000 = nicht erreichbar)
http_code() {
    curl -sk -o /dev/null -m 5 -w '%{http_code}' "$1" 2>/dev/null || true
}

# Sekunden in lesbare Dauer
human_age() {
    local s="$1"
    if   (( s < 120 ));   then echo "${s} s"
    elif (( s < 7200 ));  then echo "$((s / 60)) min"
    elif (( s < 172800 )); then echo "$((s / 3600)) h"
    else echo "$((s / 86400)) Tage"
    fi
}

# Prüft, ob eine web.yml einen gültigen bcrypt-Hash enthält (Hash wird nicht ausgegeben)
check_webyml() {
    local f="$1"
    [[ -z "$f" ]] && return 0
    if ! $SUDO test -f "$f"; then
        log_err "web.yml nicht gefunden: ${f}"
        todo "web.yml mit basic_auth_users anlegen (Konzept Schritt 5.1)"
    elif $SUDO grep -qE '^[[:space:]]+[A-Za-z0-9_-]+:[[:space:]]*\$2[aby]\$' "$f"; then
        log_ok "web.yml enthält einen bcrypt-Hash (${f})"
    else
        log_err "web.yml ohne gültigen Passwort-Hash (${f}) — z.B. weil htpasswd fehlte"
        todo "Hash neu erzeugen: 'htpasswd -nbBC 12 \"\" <Passwort> | tr -d \":\\n\"' und in ${f} eintragen"
    fi
}

# Prüft, ob ein systemd-Dienst nach wg-quick@wg0 startet
check_wg_order() {
    local unit="$1" after
    systemctl cat "$unit" &>/dev/null || return 0
    after="$(systemctl show "$unit" -p After --value 2>/dev/null)"
    if [[ "$after" == *"wg-quick@wg0.service"* ]]; then
        log_ok "${unit} startet nach wg-quick@wg0"
    else
        log_warn "${unit} startet nicht nach wg-quick@wg0 (Bindung an Tunnel-IP kann nach Reboot scheitern)"
        todo "Drop-in für ${unit} anlegen: After=/Wants=wg-quick@wg0.service (Konzept Schritt 5.1)"
    fi
}

# ---------- Vorprüfungen ----------
echo -e "${C_BOLD}Monitoring-/SIEM-Prüfung (Konzept v2)${C_RESET}"

# Root/sudo
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    command -v sudo &>/dev/null || fail "Root-Rechte oder sudo erforderlich. Skript mit sudo starten."
    SUDO="sudo"
fi

# Betriebssystem
[[ -f /etc/os-release ]] || fail "/etc/os-release nicht gefunden."
# shellcheck disable=SC1091
. /etc/os-release
OS_FAMILY="unbekannt"
if [[ "${ID:-}" =~ ^(debian|ubuntu)$ || "${ID_LIKE:-}" == *debian* ]]; then
    OS_FAMILY="debian"
elif [[ "${ID:-}" =~ ^(rhel|almalinux|rocky|centos|fedora)$ || "${ID_LIKE:-}" == *rhel* ]]; then
    OS_FAMILY="rhel"
fi
log_ok "System erkannt: ${PRETTY_NAME:-${ID:-unbekannt}}"

for tool in ss curl awk systemctl; do
    command -v "$tool" &>/dev/null || fail "Benötigtes Werkzeug fehlt: ${tool}"
done

# ---------- Schritt 1: Rolle erkennen ----------
log_step "Rolle des Servers erkennen"

if [[ -f "$WG_CONF" ]] || $SUDO test -f "$WG_CONF" 2>/dev/null; then
    TUNNEL_IP="$($SUDO awk -F'=' '/^[[:space:]]*Address/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$WG_CONF" 2>/dev/null)"
    TUNNEL_IP="${TUNNEL_IP%%/*}"
fi

if command -v docker &>/dev/null && $SUDO docker info &>/dev/null; then
    RELUTION_CTR="$($SUDO docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null | awk 'tolower($2) ~ /(^|\/)relution(:|$)/ {print $1; exit}')"
    PROM_CTR="$($SUDO docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null | awk 'tolower($2) ~ /prom\/prometheus/ {print $1; exit}')"
fi

if systemctl cat grafana-server.service &>/dev/null || [[ "$TUNNEL_IP" == "$HUB_IP" ]]; then
    ROLE="grafana"
    log_ok "Rolle: grafana-mdm (Monitoring-Server und WireGuard-Hub)"
elif systemctl cat wazuh-manager.service &>/dev/null; then
    ROLE="wazuh"
    log_ok "Rolle: Wazuh-Server"
elif [[ -n "$RELUTION_CTR" ]]; then
    ROLE="relution"; RELUTION_MODE="docker"
    log_ok "Rolle: Relution-Server (Docker, Container: ${RELUTION_CTR})"
elif systemctl list-unit-files --no-legend 2>/dev/null | grep -qi '^relution' || [[ -d /opt/relution ]]; then
    ROLE="relution"; RELUTION_MODE="nativ"
    log_ok "Rolle: Relution-Server (nativ)"
else
    log_warn "Rolle nicht erkannt: weder Grafana, Wazuh noch Relution gefunden"
    todo "Rolle unklar: Skript auf grafana-mdm, wazuh-server oder einem Relution-vServer ausführen"
fi

# ---------- Schritt 2: Systemdaten und Patchstand ----------
log_step "Systemdaten und Patchstand"

log_info "Hostname:   $(hostname -f 2>/dev/null || hostname)"
log_info "OS:         ${PRETTY_NAME:-unbekannt}"
log_info "Kernel:     $(uname -r)"
log_info "Laufzeit:   $(uptime -p 2>/dev/null || echo '?')"
log_info "CPU/RAM:    $(nproc) vCPU, $(free -h | awk '/^Mem:/{print $2" gesamt, "$7" frei"}')"
log_info "Disk /:     $(df -h / | awk 'NR==2{print $3" von "$2" belegt ("$5")"}')"
while read -r ifname addr; do
    log_info "IP:         ${addr} (${ifname})"
done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2, $4}')

case "$OS_FAMILY" in
    debian)
        UPG_LIST="$(apt list --upgradable 2>/dev/null | grep -v '^Listing' || true)"
        UPG_ALL="$(grep -c . <<<"$UPG_LIST" || true)"
        UPG_SEC="$(grep -c -- '-security' <<<"$UPG_LIST" || true)"
        STAMP=/var/lib/apt/periodic/update-success-stamp
        [[ -f "$STAMP" ]] || STAMP=/var/cache/apt/pkgcache.bin
        LAST_UPD="$(stat -c '%y' "$STAMP" 2>/dev/null | cut -d. -f1)"
        if [[ "${UPG_ALL:-0}" -eq 0 ]]; then
            log_ok "Keine ausstehenden Updates (Paketliste vom ${LAST_UPD:-?})"
        else
            log_warn "${UPG_ALL} Updates ausstehend, davon ${UPG_SEC} Sicherheitsupdates (Paketliste vom ${LAST_UPD:-?})"
            todo "Updates einspielen: 'apt update && apt full-upgrade'"
        fi
        if [[ -f /var/run/reboot-required ]]; then
            log_warn "Neustart erforderlich (/var/run/reboot-required)"
            todo "Server im Wartungsfenster neu starten"
        else
            log_ok "Kein Neustart erforderlich"
        fi
        ;;
    rhel)
        UPG_ALL="$(timeout 60 $SUDO dnf -q check-update 2>/dev/null | awk 'NF==3 && $1 ~ /\./' | grep -c . || true)"
        UPG_SEC="$(timeout 60 $SUDO dnf -q updateinfo list --security 2>/dev/null | grep -c . || true)"
        if [[ "${UPG_ALL:-0}" -eq 0 ]]; then
            log_ok "Keine ausstehenden Updates"
        else
            log_warn "${UPG_ALL} Updates ausstehend, davon ${UPG_SEC} Sicherheitsupdates"
            todo "Updates einspielen: 'dnf upgrade'"
        fi
        if command -v needs-restarting &>/dev/null; then
            if $SUDO needs-restarting -r &>/dev/null; then
                log_ok "Kein Neustart erforderlich"
            else
                log_warn "Neustart erforderlich (needs-restarting -r)"
                todo "Server im Wartungsfenster neu starten"
            fi
        fi
        ;;
    *)
        log_warn "Patchstand für diese Distribution nicht ermittelbar"
        ;;
esac

# Benötigte Werkzeuge für die Einrichtung je Rolle (nur Prüfung, keine Installation)
# Format: "Befehl:Debian-Paket:RHEL-Paket"
case "$ROLE" in
    grafana)  NEEDED_TOOLS=("wg:wireguard:wireguard-tools" "nft:nftables:nftables" "promtool:prometheus:prometheus" "openssl:openssl:openssl") ;;
    relution) NEEDED_TOOLS=("wg:wireguard:wireguard-tools" "htpasswd:apache2-utils:httpd-tools" "openssl:openssl:openssl")
              [[ "$RELUTION_MODE" == "nativ" ]] && NEEDED_TOOLS+=("promtool:prometheus:prometheus") ;;
    wazuh)    NEEDED_TOOLS=("openssl:openssl:openssl") ;;
    *)        NEEDED_TOOLS=() ;;
esac
MISSING_PKGS=()
for entry in "${NEEDED_TOOLS[@]}"; do
    IFS=':' read -r tool pkg_deb pkg_rhel <<<"$entry"
    if command -v "$tool" &>/dev/null; then
        log_ok "Werkzeug vorhanden: ${tool}"
    else
        pkg="$pkg_deb"; [[ "$OS_FAMILY" == "rhel" ]] && pkg="$pkg_rhel"
        log_warn "Werkzeug fehlt: ${tool} (Paket ${pkg})"
        MISSING_PKGS+=("$pkg")
    fi
done
if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    if [[ "$OS_FAMILY" == "rhel" ]]; then
        todo "Fehlende Pakete installieren: 'dnf install -y ${MISSING_PKGS[*]}'"
    else
        todo "Fehlende Pakete installieren: 'apt install -y ${MISSING_PKGS[*]}'"
    fi
fi

# ---------- Schritt 3: Netzwerk, WireGuard und Firewall ----------
log_step "Netzwerk, WireGuard und Firewall"

if [[ "$ROLE" == "wazuh" ]]; then
    # Wazuh-Server hängt nicht am Tunnel, sondern erreicht ihn per Route über grafana-mdm
    if ip route show "$TUNNEL_NET" 2>/dev/null | grep -q via; then
        log_ok "Route ins Tunnelnetz: $(ip route show "$TUNNEL_NET")"
    else
        log_err "Keine Route nach ${TUNNEL_NET} (Antworten an die Agents gehen verloren)"
        todo "Route '${TUNNEL_NET} via <IP grafana-mdm>' per Netplan setzen (Konzept Schritt 2.5)"
    fi
    if $SUDO test -f "$WG_CONF" || [[ "$(svc_state wg-quick@wg0)" == "active" ]]; then
        log_err "WireGuard ist auf dem Wazuh-Server eingerichtet — dort gehört es nicht hin"
        todo "WireGuard auf dem Wazuh-Server entfernen: 'systemctl disable --now wg-quick@wg0'"
    fi
else
    if ! command -v wg &>/dev/null; then
        log_err "WireGuard-Tools nicht installiert"
        todo "WireGuard installieren (Ubuntu: apt install wireguard, AlmaLinux: dnf install wireguard-tools)"
    elif ! $SUDO test -f "$WG_CONF"; then
        log_err "${WG_CONF} fehlt"
        todo "WireGuard konfigurieren (Konzept Schritt $([[ "$ROLE" == "grafana" ]] && echo 2 || echo 4))"
    else
        log_ok "${WG_CONF} vorhanden ($(perm_of "$WG_CONF"))"
        if [[ "$(perm_of "$WG_CONF")" != -rw-------* ]]; then
            log_warn "Rechte zu offen — der Private Key sollte nur für root lesbar sein"
            todo "Rechte setzen: 'chmod 600 ${WG_CONF}'"
        fi
        if $SUDO grep -q '<' "$WG_CONF"; then
            log_err "Platzhalter in spitzen Klammern in ${WG_CONF} gefunden"
            todo "Platzhalter in ${WG_CONF} durch echte Werte ersetzen"
        fi
        log_info "Tunnel-IP:  ${TUNNEL_IP:-nicht gesetzt}"
        PEER_COUNT="$($SUDO grep -c '^\[Peer\]' "$WG_CONF" || true)"
        log_info "Peers in Konfiguration: ${PEER_COUNT}"
        if [[ "$ROLE" == "relution" ]]; then
            log_info "Endpoint:   $($SUDO awk -F'=' '/^[[:space:]]*Endpoint/{gsub(/[[:space:]]/,"",$2); print $2}' "$WG_CONF")"
            log_info "AllowedIPs: $($SUDO awk -F'=' '/^[[:space:]]*AllowedIPs/{gsub(/[[:space:]]/,"",$2); print $2}' "$WG_CONF")"
        fi
    fi

    if report_svc "WireGuard (wg-quick@wg0)" wg-quick@wg0; then
        NOW="$(date +%s)"
        HS_COUNT=0
        while read -r pub ts; do
            [[ -z "${pub:-}" ]] && continue
            HS_COUNT=$((HS_COUNT + 1))
            if [[ "${ts:-0}" -eq 0 ]]; then
                log_err "Peer ${pub:0:8}…: noch nie ein Handshake"
                todo "Handshake mit Peer ${pub:0:8}… fehlt: Portweiterleitung, Kunden-Firewall und Public Keys prüfen"
            elif (( NOW - ts > 180 )); then
                log_warn "Peer ${pub:0:8}…: letzter Handshake vor $(human_age $((NOW - ts)))"
            else
                log_ok "Peer ${pub:0:8}…: Handshake vor $(human_age $((NOW - ts)))"
            fi
        done < <($SUDO wg show wg0 latest-handshakes 2>/dev/null)
        [[ $HS_COUNT -eq 0 ]] && log_warn "Noch keine Peers aktiv"
        if [[ -n "${PEER_COUNT:-}" && "$HS_COUNT" -ne "$PEER_COUNT" ]]; then
            log_warn "${PEER_COUNT} Peers in ${WG_CONF}, aber ${HS_COUNT} im laufenden Interface geladen"
            todo "Konfiguration übernehmen: 'wg syncconf wg0 <(wg-quick strip wg0)' bzw. überzählige Peer-Blöcke prüfen"
        fi
    fi
fi

if [[ "$ROLE" == "grafana" ]]; then
    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]]; then
        log_ok "IP-Weiterleitung aktiv"
    else
        log_err "IP-Weiterleitung aus — Wazuh-Events der vServer werden nicht weitergeleitet"
        todo "'net.ipv4.ip_forward=1' in /etc/sysctl.d/99-wireguard.conf, dann 'sysctl --system'"
    fi
    if report_svc "nftables" nftables; then
        if $SUDO test -f /etc/nftables.conf; then
            while read -r line; do log_info "$line"; done < <($SUDO grep -E '^[[:space:]]*define' /etc/nftables.conf)
            if $SUDO grep -q '<' /etc/nftables.conf; then
                log_err "Platzhalter in /etc/nftables.conf"
                todo "Platzhalter in /etc/nftables.conf ersetzen"
            fi
        fi
        RULESET="$($SUDO nft list ruleset 2>/dev/null)"
        grep -q 'udp dport 51820' <<<"$RULESET" && log_ok "Regel: WireGuard UDP 51820 erlaubt" \
            || { log_err "Keine Regel für UDP 51820"; todo "nftables-Regel für UDP 51820 ergänzen"; }
        grep -qE 'tcp dport \{ ?1514, ?1515 ?\}' <<<"$RULESET" && log_ok "Regel: Weiterleitung zu Wazuh (1514/1515)" \
            || { log_warn "Keine Weiterleitungsregel für Wazuh 1514/1515"; todo "Forward-Regel für Wazuh in /etc/nftables.conf aktivieren"; }
        grep -q 'iifname "wg0" drop' <<<"$RULESET" && log_ok "Regel: vServer haben keinen Zugriff auf grafana-mdm selbst" \
            || log_warn "Keine INPUT-Sperre für wg0 gefunden"
    else
        todo "nftables aktivieren: 'nft -c -f /etc/nftables.conf && systemctl enable --now nftables'"
    fi
    if command -v docker &>/dev/null || ls /etc/apt/sources.list.d/docker* &>/dev/null; then
        log_warn "Docker bzw. Docker-Paketquelle noch vorhanden (Konflikt mit nftables-Weiterleitung möglich)"
        todo "Docker entfernen und Paketquelle löschen: 'rm /etc/apt/sources.list.d/docker*' (Konzept Schritt 1.2)"
    fi
fi

if [[ "$ROLE" == "relution" ]]; then
    if command -v ufw &>/dev/null && $SUDO ufw status 2>/dev/null | grep -q 'Status: active'; then
        log_ok "ufw aktiv"
        while read -r line; do log_info "$line"; done < <($SUDO ufw status 2>/dev/null | grep -E 'wg0|9090|9100' || true)
        $SUDO ufw status 2>/dev/null | grep -qE '9090.*on wg0' || todo "ufw-Regel: 'ufw allow in on wg0 from ${HUB_IP} to any port 9090 proto tcp'"
    elif command -v firewall-cmd &>/dev/null && $SUDO firewall-cmd --state &>/dev/null; then
        log_ok "firewalld aktiv"
        ZONE="$($SUDO firewall-cmd --get-zone-of-interface=wg0 2>/dev/null || echo 'keine')"
        log_info "Zone von wg0: ${ZONE}"
        [[ "$ZONE" == "keine" ]] && todo "wg0 in eigene firewalld-Zone legen (Konzept Schritt 4.3)"
    else
        log_warn "Keine aktive Host-Firewall erkannt (ufw/firewalld)"
    fi
fi

# ---------- Schritt 4: Monitoring (Grafana / Prometheus) ----------
log_step "Monitoring-Konfiguration (Grafana / Prometheus)"

case "$ROLE" in
grafana)
    report_svc "Grafana" grafana-server
    HTTP_ADDR="$(grep -E '^[[:space:]]*http_addr' /etc/grafana/grafana.ini 2>/dev/null | head -1 | tr -d ' ')"
    log_info "grafana.ini: ${HTTP_ADDR:-http_addr nicht gesetzt (lauscht auf allen Adressen)}"
    log_info "Port 3000:  $(listen_addr 3000)"
    [[ "$(listen_addr 3000)" == *"*:3000"* || "$(listen_addr 3000)" == *"0.0.0.0:3000"* ]] && \
        todo "In /etc/grafana/grafana.ini 'http_addr = 127.0.0.1' setzen (ohne ';' davor)"
    CODE="$(http_code http://127.0.0.1:3000/api/health)"
    [[ "$CODE" == "200" ]] && log_ok "Grafana antwortet lokal (HTTP 200)" || log_err "Grafana antwortet nicht lokal (HTTP ${CODE})"

    ENV_FILE=/etc/default/grafana-server
    shopt -s nullglob
    PROV_FILES=(/etc/grafana/provisioning/datasources/*.y*ml /etc/grafana/provisioning/dashboards/*.y*ml /etc/grafana/provisioning/alerting/*.y*ml)
    shopt -u nullglob
    if [[ ${#PROV_FILES[@]} -eq 0 ]]; then
        log_warn "Keine Provisioning-Dateien gefunden"
        todo "Datenquellen anlegen (Konzept Schritt 6.2)"
    fi
    for f in "${PROV_FILES[@]}"; do
        if grafana_can_read "$f"; then
            log_ok "Provisioning: ${f} ($(perm_of "$f"))"
        else
            log_err "Provisioning: ${f} ist für den Benutzer grafana NICHT lesbar ($(perm_of "$f"))"
            todo "'chown root:grafana ${f} && chmod 640 ${f}'"
        fi
        if grep -qP '\t' "$f" 2>/dev/null; then
            log_err "  Tabulatoren in ${f} — YAML erlaubt nur Leerzeichen"
            todo "Tabs in ${f} durch Leerzeichen ersetzen"
        fi
        # Datenquellen: Name und URL (keine Passwörter)
        while IFS=$'\t' read -r name url; do
            [[ -z "$name" ]] && continue
            CODE="$(http_code "${url%/}/-/healthy")"
            case "$CODE" in
                401)      log_ok "  Datenquelle ${name}: ${url} erreichbar, Basic Auth aktiv" ;;
                200)      if [[ "$url" == *127.0.0.1* ]]; then
                              log_ok "  Datenquelle ${name}: ${url} erreichbar"
                          else
                              log_warn "  Datenquelle ${name}: ${url} erreichbar, aber OHNE Basic Auth"
                              todo "Basic Auth für Prometheus auf ${url} aktivieren (Konzept Schritt 5.1)"
                          fi ;;
                *)        log_err "  Datenquelle ${name}: ${url} nicht erreichbar (HTTP ${CODE})"
                          todo "Datenquelle ${name}: Tunnel/Prometheus auf ${url} prüfen" ;;
            esac
        done < <(awk '/^[[:space:]]*- name:/{sub(/.*name:[[:space:]]*/,""); n=$0} /^[[:space:]]*url:/{sub(/.*url:[[:space:]]*/,""); print n "\t" $0}' "$f" 2>/dev/null)
        # Verwendete Umgebungsvariablen müssen definiert sein (Werte werden nicht angezeigt)
        for var in $(grep -oE '\$\{[A-Za-z0-9_]+\}' "$f" 2>/dev/null | tr -d '${}' | sort -u); do
            if $SUDO grep -qE "^[[:space:]]*${var}=" "$ENV_FILE" 2>/dev/null; then
                log_ok "  Variable ${var} in ${ENV_FILE} definiert"
            else
                log_err "  Variable ${var} fehlt in ${ENV_FILE}"
                todo "${var}=<Passwort> in ${ENV_FILE} eintragen"
            fi
        done
    done
    if [[ -f "$ENV_FILE" ]]; then
        if grafana_can_read "$ENV_FILE" || [[ "$(perm_of "$ENV_FILE")" == *root:root* ]]; then
            log_info "${ENV_FILE}: $(perm_of "$ENV_FILE")"
        fi
        [[ "$(perm_of "$ENV_FILE")" == -rw-r--r--* ]] && { log_warn "${ENV_FILE} ist für alle lesbar (enthält Passwörter)"; todo "'chown root:grafana ${ENV_FILE} && chmod 640 ${ENV_FILE}'"; }
    fi

    report_svc "Caddy" caddy
    if [[ -f /etc/caddy/Caddyfile ]]; then
        while read -r line; do log_info "Caddyfile: ${line}"; done < <(grep -vE '^[[:space:]]*(#|$)' /etc/caddy/Caddyfile)
    fi
    LAN_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '$2 != "wg0" {sub(/\/.*/,"",$4); print $4; exit}')"
    CODE="$(http_code "https://${LAN_IP}")"
    case "$CODE" in
        200|302) log_ok "Grafana über Caddy erreichbar: https://${LAN_IP} (HTTP ${CODE})" ;;
        502)     log_err "Caddy liefert 502 — Grafana läuft nicht oder lauscht nicht auf 127.0.0.1:3000"
                 todo "Grafana-Fehler prüfen: 'journalctl -u grafana-server --since \"10 min ago\" | grep -i error'" ;;
        *)       log_err "Grafana über Caddy nicht erreichbar (HTTP ${CODE})" ;;
    esac

    if report_svc "Prometheus (lokal)" prometheus; then
        log_info "Port 9090:  $(listen_addr 9090)"
        if [[ "$(listen_addr 9090)" != "127.0.0.1:9090" ]]; then
            log_warn "Lokales Prometheus lauscht nicht nur auf 127.0.0.1"
            todo "In /etc/default/prometheus ARGS um '--web.listen-address=127.0.0.1:9090' ergänzen, dann 'systemctl restart prometheus'"
        fi
    fi
    report_svc "blackbox_exporter" prometheus-blackbox-exporter
    report_svc "node_exporter" prometheus-node-exporter
    if [[ -f /etc/prometheus/prometheus.yml ]]; then
        while read -r line; do log_info "Scrape-Job: ${line}"; done < <(awk '/job_name:/{sub(/.*job_name:[[:space:]]*/,""); print}' /etc/prometheus/prometheus.yml)
        grep -q '/probe' /etc/prometheus/prometheus.yml || todo "blackbox-Job für die Relution-URLs anlegen (Konzept Schritt 3.4)"
        if grep -qE 'localhost:9100|127\.0\.0\.1:9100' /etc/prometheus/prometheus.yml \
           && [[ "$(grep -cE 'localhost:9100|127\.0\.0\.1:9100' /etc/prometheus/prometheus.yml)" -gt 1 ]]; then
            log_warn "node_exporter wird in mehreren Jobs doppelt abgefragt"
            todo "Doppelten node_exporter-Job (z.B. Standard-Job 'node') aus /etc/prometheus/prometheus.yml entfernen"
        fi
    else
        todo "Lokales Prometheus mit blackbox einrichten (Konzept Schritt 3.4)"
    fi
    ;;

relution)
    if [[ "$RELUTION_MODE" == "docker" ]]; then
        log_info "Container:"
        while read -r line; do log_info "  ${line}"; done < <($SUDO docker ps -a --format '{{.Names}}  {{.Status}}' | grep -iE 'relution|prometheus|node|nginx|mariadb|minio')
        COMPOSE_DIR="$($SUDO docker inspect "$RELUTION_CTR" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null)"
        log_info "Compose-Verzeichnis: ${COMPOSE_DIR:-unbekannt}"
        if [[ -z "$PROM_CTR" ]]; then
            log_err "Kein Prometheus-Container gefunden"
            todo "Prometheus und node_exporter in die docker-compose.yml aufnehmen (Konzept Schritt 5.2)"
        else
            PROM_ARGS="$($SUDO docker inspect "$PROM_CTR" --format '{{join .Args " "}}' 2>/dev/null)"
            [[ "$PROM_ARGS" == *web.config.file* ]] && log_ok "Prometheus: Basic Auth konfiguriert (--web.config.file)" \
                || { log_err "Prometheus ohne --web.config.file (keine Basic Auth)"; todo "web.yml mit basic_auth_users einbinden (Konzept Schritt 5.1)"; }
            WEBYML_SRC="$($SUDO docker inspect "$PROM_CTR" --format '{{range .Mounts}}{{if eq .Destination "/etc/prometheus/web.yml"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)"
            check_webyml "$WEBYML_SRC"
            [[ "$PROM_ARGS" == *retention.size* ]] && log_ok "Prometheus: Größenlimit gesetzt" \
                || { log_warn "Prometheus ohne --storage.tsdb.retention.size"; todo "'--storage.tsdb.retention.size=5GB' ergänzen"; }
            PROM_STATE="$($SUDO docker inspect "$PROM_CTR" --format '{{.State.Status}}' 2>/dev/null)"
            if [[ "$PROM_STATE" != "running" ]]; then
                log_err "Prometheus-Container ${PROM_CTR} läuft nicht (Status: ${PROM_STATE:-unbekannt})"
                todo "Prometheus starten: 'cd ${COMPOSE_DIR:-/opt/relution} && docker compose up -d --no-deps prometheus' (vorher Handshake prüfen)"
            else
                # Service-Name statt Containername: Unterstrich im Hostnamen führt bei Tomcat zu 400
                RELUTION_SVC="$($SUDO docker inspect "$RELUTION_CTR" --format '{{ index .Config.Labels "com.docker.compose.service" }}' 2>/dev/null)"
                RELUTION_HOST="${RELUTION_SVC:-relution}"
                if ACT_OUT="$($SUDO docker exec "$PROM_CTR" wget -q -T 3 -O /dev/null "http://${RELUTION_HOST}:8099/actuator/prometheus" 2>&1)"; then
                    log_ok "Relution-Metriken aus dem Prometheus-Container abrufbar (${RELUTION_HOST}:8099)"
                elif [[ "$ACT_OUT" == *404* ]]; then
                    log_warn "Relution-Actuator gibt /actuator/prometheus nicht frei (404)"
                    todo "Wartungsfenster: MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE=health,prometheus im Service ${RELUTION_HOST}, danach ggf. 'docker compose restart nginx'"
                else
                    log_warn "Relution-Actuator aus dem Prometheus-Container nicht erreichbar (${RELUTION_HOST}:8099)"
                fi
                if $SUDO docker exec "$PROM_CTR" wget -q -T 3 -O /dev/null "http://host.docker.internal:9100/metrics" &>/dev/null; then
                    log_ok "node_exporter aus dem Prometheus-Container erreichbar"
                else
                    log_err "node_exporter aus dem Prometheus-Container nicht erreichbar (host.docker.internal:9100)"
                    todo "ufw-Regel: 'ufw allow from 172.16.0.0/12 to 172.17.0.1 port 9100 proto tcp'; extra_hosts host-gateway prüfen"
                fi
            fi
        fi
        check_wg_order docker.service
    else
        report_svc "Prometheus" prometheus
        if grep -q 'web.config.file' /etc/default/prometheus 2>/dev/null; then
            check_webyml "$(grep -oE 'web.config.file=[^ "]+' /etc/default/prometheus | cut -d= -f2)"
        fi
        CODE="$(http_code http://127.0.0.1:8099/actuator/health)"
        [[ "$CODE" == "200" ]] && log_ok "Relution-Actuator lokal erreichbar (127.0.0.1:8099)" \
            || { log_warn "Relution-Actuator auf 127.0.0.1:8099 antwortet nicht (HTTP ${CODE})"; todo "Actuator-Port der nativen Relution klären (Konzept Schritt 5.4)"; }
        if [[ "$CODE" == "200" ]]; then
            CODE="$(http_code http://127.0.0.1:8099/actuator/prometheus)"
            case "$CODE" in
                200) log_ok "Relution-Metriken freigegeben (/actuator/prometheus)" ;;
                404) log_warn "Relution-Actuator gibt /actuator/prometheus nicht frei (404)"
                     todo "Wartungsfenster: management-Block idempotent in /opt/relution/application.yml ergänzen, Relution neu starten" ;;
                *)   log_warn "/actuator/prometheus liefert HTTP ${CODE}" ;;
            esac
        fi
        check_wg_order prometheus.service
    fi

    log_info "Port 9090:  $(listen_addr 9090)"
    log_info "Port 9100:  $(listen_addr 9100)"
    if [[ -n "$TUNNEL_IP" ]]; then
        if [[ "$(listen_addr 9090)" == *"${TUNNEL_IP}:9090"* ]]; then
            log_ok "Prometheus lauscht auf der Tunnel-IP ${TUNNEL_IP}"
        elif [[ -n "$(listen_addr 9090)" ]]; then
            log_warn "Prometheus lauscht nicht (nur) auf der Tunnel-IP ${TUNNEL_IP}"
            todo "Prometheus nur an ${TUNNEL_IP}:9090 binden (Konzept Schritt 5.2/5.3)"
        else
            log_err "Port 9090 lauscht nicht"
            todo "Prometheus starten und an ${TUNNEL_IP}:9090 binden (Handshake vorher prüfen)"
        fi
        CODE="$(http_code "http://${TUNNEL_IP}:9090/-/healthy")"
        case "$CODE" in
            401) log_ok "Prometheus auf ${TUNNEL_IP}:9090 erreichbar, Basic Auth aktiv" ;;
            200) log_warn "Prometheus auf ${TUNNEL_IP}:9090 erreichbar, aber ohne Basic Auth" ;;
            *)   log_err "Prometheus auf ${TUNNEL_IP}:9090 nicht erreichbar (HTTP ${CODE})" ;;
        esac
    fi
    ;;

wazuh)
    log_info "Monitoring-Komponenten werden auf dem Wazuh-Server nicht erwartet."
    ;;

*)
    log_warn "Rolle unbekannt — Monitoring-Prüfung übersprungen"
    ;;
esac

# ---------- Schritt 5: Wazuh ----------
log_step "Wazuh"

case "$ROLE" in
wazuh)
    report_svc "Wazuh-Manager" wazuh-manager
    report_svc "Wazuh-Indexer" wazuh-indexer
    report_svc "Wazuh-Dashboard" wazuh-dashboard
    log_info "Port 1514:  $(listen_addr 1514)"
    log_info "Port 1515:  $(listen_addr 1515)"
    log_info "Port 443:   $(listen_addr 443)"
    if command -v ufw &>/dev/null && $SUDO ufw status 2>/dev/null | grep -q 'Status: active'; then
        while read -r line; do log_info "ufw: ${line}"; done < <($SUDO ufw status 2>/dev/null | grep -E '1514|1515|443|22' || true)
        $SUDO ufw status 2>/dev/null | grep -q "$TUNNEL_NET" || todo "ufw: 1514/1515 aus ${TUNNEL_NET} erlauben (Konzept Schritt 7.2)"
    else
        log_warn "ufw nicht aktiv"
        todo "Firewall auf dem Wazuh-Server einrichten (Konzept Schritt 7.2)"
    fi
    if [[ -x /var/ossec/bin/agent_control ]]; then
        log_info "Registrierte Agents:"
        while read -r line; do log_info "  ${line}"; done < <($SUDO /var/ossec/bin/agent_control -l 2>/dev/null | grep -E '^ +ID' || true)
    fi
    ;;
grafana)
    WZ="$($SUDO awk '/^define WAZUH/{print $4}' /etc/nftables.conf 2>/dev/null)"
    if [[ -n "$WZ" ]]; then
        log_info "Wazuh-Server laut nftables: ${WZ}"
        if timeout 3 bash -c "</dev/tcp/${WZ}/1514" &>/dev/null; then
            log_ok "Wazuh-Manager auf ${WZ}:1514 erreichbar"
        else
            log_warn "Wazuh-Manager auf ${WZ}:1514 nicht erreichbar (noch nicht installiert?)"
            todo "Wazuh auf ${WZ} installieren (Konzept Schritt 7.1)"
        fi
    fi
    ;;
relution)
    if report_svc "Wazuh-Agent" wazuh-agent; then
        MGR="$($SUDO grep -oP '(?<=<address>)[^<]+' /var/ossec/etc/ossec.conf 2>/dev/null | head -1)"
        log_info "Manager-Adresse: ${MGR:-?}"
        STATE="$($SUDO grep -oP "(?<=^status=')[^']+" /var/ossec/var/run/wazuh-agentd.state 2>/dev/null)"
        [[ "$STATE" == "connected" ]] && log_ok "Agent mit Manager verbunden" \
            || { log_err "Agent-Status: ${STATE:-unbekannt}"; todo "Agent-Verbindung prüfen: Tunnel, Route auf wazuh-server, ufw 1514/1515"; }
        if [[ "$OS_FAMILY" == "debian" ]]; then
            apt-mark showhold 2>/dev/null | grep -q wazuh-agent && log_ok "wazuh-agent gegen Updates gesperrt (hold)" \
                || { log_warn "wazuh-agent nicht auf hold"; todo "'apt-mark hold wazuh-agent' (Agent darf nie neuer als Manager sein)"; }
        fi
        check_wg_order wazuh-agent.service
    else
        todo "Wazuh-Agent installieren (Konzept Schritt 7.4)"
    fi
    ;;
*)
    log_warn "Rolle unbekannt — Wazuh-Prüfung übersprungen"
    ;;
esac

# ---------- Schritt 6: Härtung ----------
log_step "Härtung (offene Ports, SSH, Updates, Rechte, Images)"

# 6.1 Öffentlich lauschende Dienste
# Erlaubt je Rolle; alles andere auf einer nicht-internen Adresse wird gemeldet.
case "$ROLE" in
    relution) ALLOWED_PORTS=" 22 80 443 " ;;
    grafana)  ALLOWED_PORTS=" 22 80 443 " ;;
    wazuh)    ALLOWED_PORTS=" 22 443 1514 1515 " ;;
    *)        ALLOWED_PORTS=" 22 80 443 " ;;
esac
PUBLIC_FOUND=0
while read -r laddr proc; do
    port="${laddr##*:}"
    addr="${laddr%:*}"
    addr="${addr#[}"; addr="${addr%]}"
    # interne Adressen überspringen: localhost, Tunnel, Docker-Bridges, LAN
    case "$addr" in
        127.*|::1|10.66.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) continue ;;
    esac
    [[ "$ALLOWED_PORTS" == *" ${port} "* ]] && continue
    PUBLIC_FOUND=1
    if [[ "$proc" == *docker-proxy* ]]; then
        log_err "Port ${port} öffentlich über Docker (${laddr}) — Docker umgeht ufw"
        todo "Port ${port}: in docker-compose.yml an 127.0.0.1 binden oder 'ports:' entfernen, dann 'docker compose up -d --no-deps <service>'"
    else
        log_warn "Port ${port} lauscht auf ${laddr} (${proc:-?}) — nur durch Firewall geschützt"
        todo "Port ${port}: Dienst an localhost/Tunnel binden oder per ufw/nftables auf Admin-Netze beschränken"
    fi
done < <(ss -tlnpH 2>/dev/null | awk '{p=$6; sub(/.*\(\("/,"",p); sub(/".*/,"",p); print $4, p}' | sort -u)
[[ $PUBLIC_FOUND -eq 0 ]] && log_ok "Keine unerwarteten öffentlich lauschenden Ports (erlaubt:${ALLOWED_PORTS})"

# 6.2 SSH
if command -v sshd &>/dev/null; then
    SSHD_CFG="$($SUDO sshd -T 2>/dev/null)"
    ROOTLOGIN="$(awk '/^permitrootlogin /{print $2}' <<<"$SSHD_CFG")"
    PWAUTH="$(awk '/^passwordauthentication /{print $2}' <<<"$SSHD_CFG")"
    case "$ROOTLOGIN" in
        no)               log_ok "SSH: Root-Login deaktiviert" ;;
        prohibit-password|without-password) log_warn "SSH: Root-Login nur mit Schlüssel erlaubt"
                          todo "SSH: 'PermitRootLogin no' setzen (persönliche Konten + sudo)" ;;
        *)                log_err "SSH: Root-Login erlaubt (${ROOTLOGIN:-unbekannt})"
                          todo "SSH: 'PermitRootLogin no' setzen" ;;
    esac
    if [[ "$PWAUTH" == "no" ]]; then
        log_ok "SSH: Passwort-Anmeldung deaktiviert"
    else
        log_warn "SSH: Passwort-Anmeldung erlaubt"
        todo "SSH: Schlüssel hinterlegen, dann 'PasswordAuthentication no' und 'systemctl reload ssh'"
    fi
    if command -v ufw &>/dev/null && $SUDO ufw status 2>/dev/null | grep -q 'Status: active'; then
        if $SUDO ufw status 2>/dev/null | grep -E '^(22(/tcp)?|OpenSSH)[[:space:]]' | grep -q 'Anywhere'; then
            log_warn "SSH (22) per ufw für alle Quellen freigegeben"
            todo "SSH per ufw auf Admin-IPs bzw. VPN-Pool beschränken"
        else
            log_ok "SSH nicht für alle Quellen freigegeben (ufw)"
        fi
    fi
fi

# 6.3 Brute-Force-Schutz
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    log_ok "fail2ban aktiv"
elif systemctl is-active --quiet crowdsec 2>/dev/null; then
    log_ok "CrowdSec aktiv"
elif systemctl is-active --quiet imunify360 2>/dev/null; then
    log_ok "Imunify360 aktiv"
else
    log_warn "Kein Brute-Force-Schutz aktiv (fail2ban/CrowdSec)"
    todo "fail2ban oder CrowdSec installieren (mindestens für SSH)"
fi

# 6.4 Automatische Sicherheitsupdates und Laufzeit
if [[ "$OS_FAMILY" == "debian" ]]; then
    if dpkg-query -W -f='${db:Status-Status}' unattended-upgrades 2>/dev/null | grep -q installed \
       && grep -qE 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
        log_ok "unattended-upgrades aktiv"
    else
        log_warn "Automatische Sicherheitsupdates nicht aktiv"
        todo "'apt install unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades'"
    fi
elif [[ "$OS_FAMILY" == "rhel" ]]; then
    if systemctl is-enabled --quiet dnf-automatic.timer 2>/dev/null || systemctl is-enabled --quiet dnf-automatic-install.timer 2>/dev/null; then
        log_ok "dnf-automatic aktiv"
    else
        log_warn "Automatische Sicherheitsupdates nicht aktiv"
        todo "dnf-automatic einrichten (upgrade_type = security)"
    fi
fi
UPTIME_DAYS=$(( $(cut -d. -f1 /proc/uptime) / 86400 ))
if (( UPTIME_DAYS > 90 )); then
    log_warn "Letzter Neustart vor ${UPTIME_DAYS} Tagen — Kernel-Updates wirken erst nach Reboot"
else
    log_ok "Letzter Neustart vor ${UPTIME_DAYS} Tagen"
fi

# 6.5 Dateirechte für Zugangsdaten und Schlüssel
check_secret_file() {
    local f="$1" perm
    $SUDO test -f "$f" || return 0
    perm="$($SUDO stat -c '%a' "$f" 2>/dev/null)"
    if (( (8#${perm:-0} & 8#007) != 0 )); then
        log_err "${f} ist für alle lesbar/schreibbar (${perm}, $(perm_of "$f"))"
        todo "Rechte einschränken: 'chmod o-rwx ${f}' (Schlüssel: chown root:root, chmod 600)"
    elif (( (8#${perm:-0} & 8#020) != 0 )); then
        log_warn "${f} ist für die Gruppe schreibbar (${perm}, $(perm_of "$f"))"
        todo "Rechte einschränken: 'chmod g-w ${f}'"
    else
        log_ok "Rechte in Ordnung: ${f} (${perm})"
    fi
}
SECRET_FILES=()
if [[ "$ROLE" == "relution" ]]; then
    for d in /opt/relution "${COMPOSE_DIR:-}"; do
        [[ -n "$d" && -d "$d" ]] || continue
        while IFS= read -r f; do SECRET_FILES+=("$f"); done < <(
            $SUDO find "$d" -maxdepth 2 -type f \( -name 'application*.yml' -o -name '.env' -o -name '*.key' -o -name 'relution.cnf' \) 2>/dev/null
            $SUDO find "$d" -maxdepth 2 -type f \( -name '*.pem' -o -name 'docker-compose*.yml' \) -exec $SUDO grep -lE 'PRIVATE KEY|PASSWORD|SECRET|_KEY=' {} + 2>/dev/null
        )
    done
elif [[ "$ROLE" == "grafana" ]]; then
    SECRET_FILES=(/etc/default/grafana-server /etc/grafana/provisioning/datasources/monitoring.yml /etc/wireguard/wg0.conf)
fi
mapfile -t SECRET_FILES < <(printf '%s\n' "${SECRET_FILES[@]}" | sort -u | grep -v '^$')
[[ ${#SECRET_FILES[@]} -eq 0 ]] && log_info "Keine Dateien mit Zugangsdaten gefunden"
for f in "${SECRET_FILES[@]}"; do check_secret_file "$f"; done

# 6.6 Docker: Images mit :latest und Gruppenmitglieder
if command -v docker &>/dev/null && $SUDO docker info &>/dev/null; then
    LATEST_IMGS="$($SUDO docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | awk '$2 ~ /:latest$/ || $2 !~ /:/ {print $1" ("$2")"}' | paste -sd',' -)"
    if [[ -n "$LATEST_IMGS" ]]; then
        log_warn "Container ohne feste Version: ${LATEST_IMGS//,/, }"
        todo "Images auf feste Versionen pinnen (Neuerstellung kann sonst ungeplant updaten)"
    else
        log_ok "Alle Container mit fester Image-Version"
    fi
    DOCKER_MEMBERS="$(getent group docker | cut -d: -f4)"
    [[ -n "$DOCKER_MEMBERS" ]] && log_info "Mitglieder der Gruppe docker (root-gleich): ${DOCKER_MEMBERS}"
fi
SUDO_MEMBERS="$(getent group sudo wheel 2>/dev/null | cut -d: -f4 | paste -sd',' - | sed 's/^,//;s/,$//')"
[[ -n "$SUDO_MEMBERS" ]] && log_info "Mitglieder sudo/wheel: ${SUDO_MEMBERS} — ehemalige Bearbeiter entfernen"

# ---------- Schritt 7: Zusammenfassung ----------
log_step "Zusammenfassung und nächste Schritte"

case "$ROLE" in
    grafana)  log_ok "Rolle: grafana-mdm (Hub ${TUNNEL_IP:-?})" ;;
    wazuh)    log_ok "Rolle: Wazuh-Server" ;;
    relution) log_ok "Rolle: Relution-Server (${RELUTION_MODE}, Tunnel-IP ${TUNNEL_IP:-keine})" ;;
    *)        log_warn "Rolle: unbekannt" ;;
esac

if [[ ${#TODO[@]} -gt 0 ]]; then
    echo -e "\n  ${C_BOLD}Offene Punkte auf diesem Server:${C_RESET}"
    i=0
    for t in "${TODO[@]}"; do
        i=$((i + 1))
        echo "    ${i}. ${t}"
    done
else
    log_ok "Auf diesem Server keine offenen Punkte gefunden"
fi

echo -e "\n  ${C_BOLD}Weitere Schritte laut Konzept:${C_RESET}"
case "$ROLE" in
    grafana)
        log_info "1. Portweiterleitung UDP 51820 testen (tcpdump -ni <LAN-Interface> udp port 51820)"
        log_info "2. Je vServer: Peer in ${WG_CONF} eintragen, 'wg syncconf wg0 <(wg-quick strip wg0)'"
        log_info "3. Je vServer: Datenquelle in provisioning/datasources ergänzen, URL in blackbox-Job aufnehmen"
        log_info "4. Dashboards importieren (Relution, Node Exporter Full 1860), Alert-Regeln und Contact Points" ;;
    wazuh)
        log_info "1. Wazuh installieren bzw. Dienste prüfen (Konzept Schritt 7.1)"
        log_info "2. Agent-Gruppen relution-docker / relution-native anlegen (Schritt 7.3)"
        log_info "3. Nach Anbindung der Pilot-vServer: 2–4 Wochen Regeln tunen" ;;
    relution)
        log_info "1. Tunnel prüfen: 'wg show' muss einen aktuellen Handshake zeigen"
        log_info "2. Prometheus/node_exporter auf Tunnel-IP mit Basic Auth (Schritt 5)"
        log_info "3. Auf grafana-mdm Datenquelle für diesen Server anlegen (Schritt 6.2)"
        log_info "4. Wazuh-Agent installieren und Verbindung prüfen (Schritt 7.4)" ;;
    *)
        log_info "Skript auf grafana-mdm, wazuh-server oder einem Relution-vServer ausführen." ;;
esac

if [[ ${#TODO[@]} -eq 0 ]]; then
    echo -e "\n${C_GREEN}${C_BOLD}Prüfung erfolgreich abgeschlossen!${C_RESET}"
else
    echo -e "\n${C_YELLOW}${C_BOLD}Prüfung abgeschlossen — ${#TODO[@]} offene Punkte.${C_RESET}"
fi

exit 0
