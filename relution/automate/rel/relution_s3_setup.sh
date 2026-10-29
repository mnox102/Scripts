#!/usr/bin/env bash

# Richtet den S3-Objektspeicher für Relution ein:
# Docker aus dem offiziellen Debian-Repo, SeaweedFS im "mini"-Modus, S3-Benutzer
# mit expliziten Rechten, Bucket und eine Firewall-Regel, die die S3-API nur für
# den Relution-App-Server öffnet.
# Quelle(n):
#   https://docs.docker.com/engine/install/debian/
#   https://docs.docker.com/engine/daemon/proxy/
#   https://hub.relution.io/en/docs/installation/object-storage/seaweedfs/
#   https://docs.docker.com/engine/network/packet-filtering-firewalls/
# Mit Statusanzeige und Fehlerprüfung nach jedem Schritt.
# Getestet: bash -n, shellcheck, Teillogik mit Fake-Eingaben – nicht auf einem Zielsystem ausgeführt.

# shellcheck disable=SC2329  # Hilfsfunktionen werden indirekt über run() aufgerufen
set -uo pipefail   # bewusst ohne -e: Fehler werden explizit über run()/fail() behandelt

# ================= VOR DEM START ANPASSEN =================
FS_IP="<FS-IP>"            # eigene IP dieses Servers (S3-API lauscht hier)
APP_IP="<APP-IP>"          # einziger erlaubter S3-Client
PROXY_URL=""               # z.B. "http://proxy.example.de:3128"; leer = kein Proxy
NO_PROXY_EXTRA=""         # weitere Ausnahmen, kommagetrennt, z.B. ".example.de"
SEAWEED_IMAGE="chrislusf/seaweedfs:4.05"   # Version vor Ort prüfen und pinnen
DATA_DIR="/srv/seaweedfs"
S3_USER="relution"
S3_BUCKET="relution"
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

readonly SW_DIR="/opt/seaweedfs"
readonly CRED_FILE="/root/relution-s3-credentials.txt"

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
require_vars() {
    local name
    for name in "$@"; do
        [[ -n "${!name}" && "${!name}" != *"<"* ]] \
            || fail "Variable ${name} ist nicht gesetzt (Block 'VOR DEM START ANPASSEN' oben im Skript)."
    done
}

gen_secret() {   # $1 = Länge, $2 = Zeichenvorrat
    local s
    s="$(tr -dc "${2:-A-Za-z0-9}" </dev/urandom 2>/dev/null | head -c "$1")"
    printf '%s' "$s"
}

write_file() {   # $1 = Rechte, $2 = Ziel; Inhalt kommt aus $TMP_FILE
    $SUDO install -m "$1" "$TMP_FILE" "$2"
}

# Ein Befehl an die SeaweedFS-Admin-Shell (Ausgabe auf stdout)
weed_cmd() {
    printf '%s\nexit\n' "$1" | $SUDO docker exec -i seaweedfs weed shell 2>&1
}

# Benutzer mit expliziten Rechten setzen – ohne Argumente, damit Keys nicht im Log stehen
configure_s3_user() {
    weed_cmd "s3.configure -user=${S3_USER} -access_key=${S3_ACCESS_KEY} -secret_key=${S3_SECRET_KEY} -buckets=${S3_BUCKET} -actions=Read,Write,List,Tagging -apply" >/dev/null
}

save_credentials() {
    local tmp
    tmp="$(mktemp)"
    printf 'S3_ENDPOINT=http://%s:8333\nS3_BUCKET=%s\nS3_ACCESS_KEY=%s\nS3_SECRET_KEY=%s\nUI_PASSWORD=%s\n' \
        "$FS_IP" "$S3_BUCKET" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" "$UI_PASSWORD" > "$tmp"
    $SUDO install -m 0600 -o root -g root "$tmp" "$CRED_FILE"
    rm -f "$tmp"
}

cred_value() {   # liest einen Wert aus der gespeicherten Zugangsdatei
    $SUDO grep "^$1=" "$CRED_FILE" 2>/dev/null | cut -d= -f2-
}

# ---------- Vorprüfungen ----------
echo -e "${C_BOLD}Relution – Objektspeicher (SeaweedFS) einrichten${C_RESET}"

# Root/sudo
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    command -v sudo &>/dev/null \
        || fail "Root-Rechte erforderlich, sudo ist nicht installiert (typisch für Debian-Minimal). Als root anmelden mit 'su -' (mit Bindestrich) und Skript erneut starten."
    SUDO="sudo"
fi

# Betriebssystem
[[ -f /etc/os-release ]] || fail "/etc/os-release nicht gefunden."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" ]] \
    || fail "Docker-Repo-Pfad ist für Debian gesetzt (erkannt: ${PRETTY_NAME:-${ID:-unbekannt}})."
[[ -n "${VERSION_CODENAME:-}" ]] || fail "VERSION_CODENAME fehlt in /etc/os-release."
log_ok "System erkannt: ${PRETTY_NAME:-${ID}} (${VERSION_CODENAME})"

require_vars FS_IP APP_IP SEAWEED_IMAGE DATA_DIR S3_USER S3_BUCKET
hostname -I | tr ' ' '\n' | grep -qx "${FS_IP}" \
    || fail "FS_IP ${FS_IP} ist auf diesem Server nicht konfiguriert ('hostname -I' prüfen)."

# Proxy für curl in diesem Skript
NO_PROXY_LIST="localhost,127.0.0.1,${FS_IP},${APP_IP}${NO_PROXY_EXTRA:+,${NO_PROXY_EXTRA}}"
if [[ -n "$PROXY_URL" ]]; then
    export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
    export no_proxy="${NO_PROXY_LIST}"
    log_ok "Ausgehender Proxy: ${PROXY_URL}"
else
    log_ok "Kein Proxy konfiguriert – direkter Internetzugang erwartet"
fi

# Bereits erledigt? (Idempotenz)
if command -v docker &>/dev/null && $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx seaweedfs; then
    log_warn "Container 'seaweedfs' existiert bereits – Konfiguration wird erneut angewendet, Daten bleiben erhalten."
    confirm "Trotzdem fortfahren?" y || { echo "Abgebrochen."; exit 0; }
fi

# ---------- Schritt 1: Basis-Pakete ----------
log_step "Basiswerkzeuge und Zeitsynchronisation"

run "Paketlisten aktualisiert (bei Fehler: Repo-/Proxy-Einstellung für apt prüfen)" $SUDO apt-get update
run "Pakete installiert" $SUDO env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y iproute2 procps ca-certificates curl gnupg chrony cron bind9-dnsutils netcat-openbsd less iptables
run "Zeitzone Europe/Berlin" $SUDO timedatectl set-timezone Europe/Berlin
run "chrony aktiviert" $SUDO systemctl enable --now chrony

# ---------- Schritt 2: Docker installieren ----------
log_step "Docker installieren (offizielles Debian-Repo)"

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    log_ok "Docker bereits vorhanden: $(docker --version)"
else
    curl -fsI "https://download.docker.com/linux/debian/dists/${VERSION_CODENAME}/Release" >/dev/null 2>&1 \
        || fail "download.docker.com nicht erreichbar – Proxy/Allowlist prüfen (PROXY_URL oben im Skript)."
    log_ok "Docker-Repo erreichbar (${VERSION_CODENAME})"

    TMP_FILE="$(mktemp)"
    run "Docker-GPG-Schlüssel geladen" curl -fsSL https://download.docker.com/linux/debian/gpg -o "$TMP_FILE"
    run "Keyring-Verzeichnis" $SUDO install -m 0755 -d /etc/apt/keyrings
    run "Docker-GPG-Schlüssel installiert" write_file 0644 /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian %s stable\n' \
        "$(dpkg --print-architecture)" "$VERSION_CODENAME" > "$TMP_FILE"
    run "Docker-Paketquelle eingetragen" write_file 0644 /etc/apt/sources.list.d/docker.list
    rm -f "$TMP_FILE"

    run "Paketlisten aktualisiert" $SUDO apt-get update
    run "Docker-Pakete installiert" $SUDO env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# ---------- Schritt 3: Docker-Dienst und Proxy ----------
log_step "Docker-Dienst (inkl. Proxy für Image-Downloads)"

if [[ -n "$PROXY_URL" ]]; then
    TMP_FILE="$(mktemp)"
    cat > "$TMP_FILE" <<EOF
[Service]
Environment="HTTP_PROXY=${PROXY_URL}"
Environment="HTTPS_PROXY=${PROXY_URL}"
Environment="NO_PROXY=${NO_PROXY_LIST}"
EOF
    run "Drop-in-Verzeichnis" $SUDO install -m 0755 -d /etc/systemd/system/docker.service.d
    run "Proxy-Drop-in geschrieben" write_file 0644 /etc/systemd/system/docker.service.d/http-proxy.conf
    rm -f "$TMP_FILE"
    run "systemd neu geladen" $SUDO systemctl daemon-reload
fi
run "Docker aktiviert" $SUDO systemctl enable docker
run "Docker (neu) gestartet" $SUDO systemctl restart docker
run "Testcontainer hello-world (Pull über Proxy)" $SUDO docker run --rm hello-world

# ---------- Schritt 4: SeaweedFS starten ----------
log_step "SeaweedFS starten"

# Zugangsdaten wiederverwenden, falls bereits erzeugt
S3_ACCESS_KEY="$(cred_value S3_ACCESS_KEY)"
S3_SECRET_KEY="$(cred_value S3_SECRET_KEY)"
UI_PASSWORD="$(cred_value UI_PASSWORD)"
[[ -n "$S3_ACCESS_KEY" ]] || S3_ACCESS_KEY="$(gen_secret 20 'A-Z0-9')"
[[ -n "$S3_SECRET_KEY" ]] || S3_SECRET_KEY="$(gen_secret 40)"
[[ -n "$UI_PASSWORD" ]]   || UI_PASSWORD="$(gen_secret 24)"
run "Zugangsdaten gespeichert (${CRED_FILE}, nur root)" save_credentials

run "Datenverzeichnis ${DATA_DIR}" $SUDO install -d -m 0750 "$DATA_DIR"
run "Compose-Verzeichnis ${SW_DIR}" $SUDO install -d -m 0750 "$SW_DIR"
FREE_GB="$(df -BG --output=avail "$DATA_DIR" | tail -n 1 | tr -dc '0-9')"
(( FREE_GB >= 20 )) || log_warn "Nur ${FREE_GB} GB frei unter ${DATA_DIR} – für den Start ok, bei vielen Eigen-Apps zu wenig."
log_ok "Freier Speicher unter ${DATA_DIR}: ${FREE_GB} GB"

TMP_FILE="$(mktemp)"
cat > "$TMP_FILE" <<EOF
services:
  seaweedfs:
    image: ${SEAWEED_IMAGE}
    container_name: seaweedfs
    restart: unless-stopped
    command: ["mini", "-dir=/data", "-admin.dataDir=/data/admin", "-admin.password=${UI_PASSWORD}"]
    ports:
      - "${FS_IP}:8333:8333"        # S3-API, Freigabe nur für den App-Server (DOCKER-USER)
      - "127.0.0.1:23646:23646"     # Web-UI nur lokal, Zugriff per SSH-Tunnel
    volumes:
      - ${DATA_DIR}:/data
EOF
run "compose.yaml geschrieben (enthält UI-Passwort, nur root)" write_file 0600 "${SW_DIR}/compose.yaml"
rm -f "$TMP_FILE"

run "Image ${SEAWEED_IMAGE} geladen" $SUDO docker compose -f "${SW_DIR}/compose.yaml" pull
run "Container gestartet" $SUDO docker compose -f "${SW_DIR}/compose.yaml" up -d

S3_READY=""
for _ in $(seq 1 30); do
    code="$(curl --noproxy '*' -s -m 3 -o /dev/null -w '%{http_code}' "http://${FS_IP}:8333" 2>/dev/null || true)"
    if [[ "$code" == "403" || "$code" == "200" ]]; then S3_READY=1; break; fi
    sleep 2
done
[[ -n "$S3_READY" ]] || fail "S3-API antwortet nicht auf ${FS_IP}:8333 – 'docker logs seaweedfs' prüfen."
log_ok "S3-API antwortet auf ${FS_IP}:8333"

# ---------- Schritt 5: S3-Benutzer und Bucket ----------
log_step "S3-Benutzer und Bucket"

SHELL_READY=""
for _ in $(seq 1 20); do
    out="$(weed_cmd "s3.bucket.list")"
    if [[ -n "$out" ]] && ! grep -qiE 'error|refused|no leader' <<<"$out"; then SHELL_READY=1; break; fi
    sleep 3
done
[[ -n "$SHELL_READY" ]] || fail "weed shell nicht bereit – 'docker exec -it seaweedfs weed shell' manuell testen."

if weed_cmd "s3.bucket.list" | grep -qw "$S3_BUCKET"; then
    log_ok "Bucket ${S3_BUCKET} existiert bereits"
else
    run "Bucket ${S3_BUCKET} angelegt" weed_cmd "s3.bucket.create -name ${S3_BUCKET}"
    weed_cmd "s3.bucket.list" | grep -qw "$S3_BUCKET" || fail "Bucket ${S3_BUCKET} nach dem Anlegen nicht sichtbar."
fi

# Wichtig: Benutzer aus dem Web-UI haben keine Aktionen ("actions": []) -> 403 AccessDenied
run "Benutzer ${S3_USER}: Read, Write, List, Tagging auf ${S3_BUCKET}" configure_s3_user
S3_CFG="$(weed_cmd "s3.configure")"
if grep -q "Write:${S3_BUCKET}" <<<"$S3_CFG" && grep -q "$S3_ACCESS_KEY" <<<"$S3_CFG"; then
    log_ok "Rechte geprüft: Write:${S3_BUCKET} gesetzt, Access Key aktiv"
else
    fail "Rechte nicht wie erwartet gesetzt – in weed shell 's3.configure' ausgeben und prüfen."
fi

# ---------- Schritt 6: Firewall ----------
log_step "S3-API nur für den App-Server freigeben (DOCKER-USER)"

IPT="$(command -v iptables || echo /usr/sbin/iptables)"
$SUDO "$IPT" -L DOCKER-USER -n &>/dev/null \
    || fail "Kette DOCKER-USER fehlt – 'docker info | grep -i firewall' prüfen (nftables-Backend?)."

RULE="-p tcp -m conntrack --ctorigdstport 8333 --ctdir ORIGINAL ! -s ${APP_IP} -j DROP"
TMP_FILE="$(mktemp)"
cat > "$TMP_FILE" <<EOF
[Unit]
Description=DOCKER-USER Regeln (S3 nur vom Relution-App-Server)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '${IPT} -C DOCKER-USER ${RULE} 2>/dev/null || ${IPT} -I DOCKER-USER ${RULE}'

[Install]
WantedBy=multi-user.target
EOF
run "systemd-Unit docker-user-fw.service" write_file 0644 /etc/systemd/system/docker-user-fw.service
rm -f "$TMP_FILE"
run "systemd neu geladen" $SUDO systemctl daemon-reload
run "Firewall-Regel aktiviert" $SUDO systemctl enable --now docker-user-fw.service
# shellcheck disable=SC2086  # RULE muss in einzelne Argumente zerfallen
if $SUDO "$IPT" -C DOCKER-USER $RULE 2>/dev/null; then
    log_ok "Regel aktiv: 8333 nur von ${APP_IP}"
else
    fail "Regel nicht aktiv – 'iptables -L DOCKER-USER -n -v' prüfen."
fi

# ---------- Schritt 7: Zusammenfassung ----------
log_step "Zusammenfassung"

log_ok "SeaweedFS: $($SUDO docker inspect -f '{{.Config.Image}} – {{.State.Status}}' seaweedfs 2>/dev/null)"
log_ok "S3-Endpunkt: http://${FS_IP}:8333, Bucket ${S3_BUCKET}"
log_ok "Daten: ${DATA_DIR} (in die VM-Sicherung aufnehmen!)"
echo
echo -e "  ${C_BOLD}Für das App-Server-Skript übernehmen:${C_RESET}"
echo "    FS_HOST=\"${FS_IP}\""
echo "    S3_ACCESS_KEY=\"${S3_ACCESS_KEY}\""
echo "    S3_SECRET_KEY=\"${S3_SECRET_KEY}\""
log_warn "Zugangsdaten liegen auch in ${CRED_FILE} – nicht in Tickets/Chats kopieren."
log_warn "Web-UI: ssh -L 23646:localhost:23646 <user>@${FS_IP}, dann http://localhost:23646"
echo -e "\n${C_GREEN}${C_BOLD}Objektspeicher-Einrichtung erfolgreich abgeschlossen!${C_RESET}"

exit 0
