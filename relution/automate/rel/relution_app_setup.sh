#!/usr/bin/env bash

# Richtet einen Relution-App-Server ein:
# Docker aus dem offiziellen Debian-Repo, Relution + nginx per Docker Compose,
# externe PostgreSQL-Datenbank, SeaweedFS als Objektspeicher, Zugangsdaten als
# Docker-Secrets (keine Klartext-Keys in compose.yaml), statische Zertifikate.
# Quelle(n):
#   https://hub.relution.io/en/docs/installation/installation/dockercompose/
#   https://hub.relution.io/en/docs/installation/object-storage/configure-relution/
#   https://hub.relution.io/en/docs/installation/requirements/
#   https://docs.docker.com/engine/install/debian/
#   https://docs.docker.com/engine/daemon/proxy/
# Mit Statusanzeige und Fehlerprüfung nach jedem Schritt.
# Getestet: bash -n, shellcheck, Teillogik (YAML-/nginx-Anpassung) mit Fake-Eingaben –
# NICHT auf der Ziel-VM und NICHT gegen das aktuelle Relution-Template.

# shellcheck disable=SC2329  # Hilfsfunktionen werden indirekt über run() aufgerufen
set -uo pipefail   # bewusst ohne -e: Fehler werden explizit über run()/fail() behandelt

# ================= VOR DEM START ANPASSEN =================
EXT_HOSTNAME="<EXT-HOSTNAME>"   # externe URL in Relution (Geräte), z.B. "mdm.example.de"
PORTAL_HOSTNAME=""              # optional: zweiter Name im nginx, z.B. "portal.example.de"
ADMIN_EMAIL="<ADMIN-MAIL>"

DB_HOST="<DB-IP>"            # aus Ausgabe relution-db-setup.sh
DB_PASSWORD="<DB-PASSWORT>"  # aus Ausgabe relution-db-setup.sh

FS_HOST="<FS-IP>"            # aus Ausgabe relution-s3-setup.sh
# shellcheck disable=SC2034  # indirekt über write_secret / require_vars genutzt
S3_ACCESS_KEY="<ACCESS-KEY>" # aus Ausgabe relution-s3-setup.sh
# shellcheck disable=SC2034  # indirekt über write_secret / require_vars genutzt
S3_SECRET_KEY="<SECRET-KEY>" # aus Ausgabe relution-s3-setup.sh
S3_BUCKET="relution"

CERT_FULLCHAIN="/root/certs/fullchain.pem"   # Serverzertifikat + Zwischenzertifikate
CERT_KEY="/root/certs/server.key"            # privater Schlüssel

PROXY_HOST=""                # z.B. "proxy.example.de"; leer = kein Proxy
PROXY_PORT=""                # z.B. "3128"
NO_PROXY_EXTRA=""            # weitere Ausnahmen, kommagetrennt, z.B. ".example.de"

RELUTION_IMAGE="relution/relution:latest"    # nach erstem Start auf Version >= 26.0 pinnen
MAX_UPLOAD="4G"              # max. Größe einer hochgeladenen App (nginx client_max_body_size)
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

readonly BASE_DIR="/opt/relution"
readonly SETUP_URL="https://raw.githubusercontent.com/relution-io/relution-setup/master/docker/Linux/opt/relution"
readonly START_TIMEOUT=600   # Sekunden bis Relution antworten muss

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
require_vars() {
    local name
    for name in "$@"; do
        [[ -n "${!name}" && "${!name}" != *"<"* ]] \
            || fail "Variable ${name} ist nicht gesetzt (Block 'VOR DEM START ANPASSEN' oben im Skript)."
    done
}

gen_secret() {
    local s
    s="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$1")"
    printf '%s' "$s"
}

write_file() {   # $1 = Rechte, $2 = Ziel; Inhalt kommt aus $TMP_FILE
    $SUDO install -m "$1" "$TMP_FILE" "$2"
}

# DB-Login testen – Passwort über Umgebung, damit es nicht im Log steht
check_db() {
    PGPASSWORD="$DB_PASSWORD" psql -X \
        "host=${DB_HOST} port=5432 user=relution dbname=relution connect_timeout=5" -tAc 'SELECT 1'
}

# Secret-Datei schreiben: $1 = Dateiname, $2 = NAME der Variable (Wert nicht im Log)
write_secret() {
    local tmp
    tmp="$(mktemp)"
    printf '%s' "${!2}" > "$tmp"
    $SUDO install -m 0400 -o "$RUID" -g 0 "$tmp" "${BASE_DIR}/secrets/$1"
    rm -f "$tmp"
}

# S3-Block direkt unter "relution:" einfügen (zwei Leerzeichen Einrückung wie im Template)
patch_storage() {
    awk -v ep="http://${FS_HOST}:8333" -v bucket="$S3_BUCKET" '
        { print }
        !done && /^relution:[[:space:]]*$/ {
            print "  storage:"
            print "    resourceStorageType: S3"
            print "    s3:"
            print "      customEndpoint: " ep
            print "      accessKey: ${s3_access_key}"
            print "      secretKey: ${s3_secret_key}"
            print "      bucketName: " bucket
            done = 1
        }' "$1" > "$1.new" && mv "$1.new" "$1"
}

http_code() {
    curl --noproxy '*' -sk -m 5 -o /dev/null -w '%{http_code}' \
        --resolve "${EXT_HOSTNAME}:443:127.0.0.1" "https://${EXT_HOSTNAME}/" 2>/dev/null || true
}

# ---------- Vorprüfungen ----------
echo -e "${C_BOLD}Relution – App-Server einrichten${C_RESET}"

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

require_vars EXT_HOSTNAME ADMIN_EMAIL DB_HOST DB_PASSWORD \
    FS_HOST S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET CERT_FULLCHAIN CERT_KEY RELUTION_IMAGE
$SUDO test -r "$CERT_FULLCHAIN" || fail "Zertifikat ${CERT_FULLCHAIN} nicht gefunden – Datei vorher auf den Server kopieren."
$SUDO test -r "$CERT_KEY"       || fail "Schlüssel ${CERT_KEY} nicht gefunden – Datei vorher auf den Server kopieren."

# Proxy für curl in diesem Skript
PROXY_URL=""
NO_PROXY_LIST="localhost,127.0.0.1,${DB_HOST},${FS_HOST}${NO_PROXY_EXTRA:+,${NO_PROXY_EXTRA}}"
SERVER_NAMES="${EXT_HOSTNAME}${PORTAL_HOSTNAME:+ ${PORTAL_HOSTNAME}}"
if [[ -n "$PROXY_HOST" ]]; then
    [[ -n "$PROXY_PORT" ]] || fail "PROXY_PORT fehlt (PROXY_HOST ist gesetzt)."
    PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
    export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL" no_proxy="$NO_PROXY_LIST"
    log_ok "Ausgehender Proxy: ${PROXY_URL}"
else
    log_ok "Kein Proxy konfiguriert – direkter Internetzugang erwartet"
fi

# Bereits erledigt? (Idempotenz)
if [[ -f "${BASE_DIR}/compose.yaml" ]]; then
    log_warn "${BASE_DIR}/compose.yaml existiert bereits – Dateien werden neu geschrieben (Sicherung *.bak)."
    log_warn "Das Admin-Passwort bleibt erhalten; die Datenbank wird nicht verändert."
    confirm "Trotzdem fortfahren?" y || { echo "Abgebrochen."; exit 0; }
fi

# ---------- Schritt 1: Basis-Pakete ----------
log_step "Basiswerkzeuge und Zeitsynchronisation"

run "Paketlisten aktualisiert (bei Fehler: Repo-/Proxy-Einstellung für apt prüfen)" $SUDO apt-get update
run "Pakete installiert" $SUDO env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y iproute2 procps ca-certificates curl gnupg chrony cron bind9-dnsutils netcat-openbsd less openssl postgresql-client
run "Zeitzone Europe/Berlin" $SUDO timedatectl set-timezone Europe/Berlin
run "chrony aktiviert" $SUDO systemctl enable --now chrony

# ---------- Schritt 2: Docker installieren ----------
log_step "Docker installieren (offizielles Debian-Repo)"

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    log_ok "Docker bereits vorhanden: $(docker --version)"
else
    curl -fsI "https://download.docker.com/linux/debian/dists/${VERSION_CODENAME}/Release" >/dev/null 2>&1 \
        || fail "download.docker.com nicht erreichbar – Proxy/Allowlist prüfen (PROXY_HOST oben im Skript)."
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

# ---------- Schritt 4: Vorabtests ----------
log_step "Vorabtests: Datenbank, Objektspeicher, Zertifikat"

run "Datenbank ${DB_HOST}:5432 – Login relution" check_db

code="$(curl --noproxy '*' -s -m 5 -o /dev/null -w '%{http_code}' "http://${FS_HOST}:8333" 2>/dev/null || true)"
case "$code" in
    403|200) log_ok "S3-API ${FS_HOST}:8333 erreichbar (HTTP ${code})" ;;
    *)       fail "S3-API ${FS_HOST}:8333 nicht erreichbar (HTTP '${code}') – Firewall/DOCKER-USER auf dem Fileserver prüfen." ;;
esac

CERT_COUNT="$($SUDO grep -c 'BEGIN CERTIFICATE' "$CERT_FULLCHAIN")"
if (( CERT_COUNT >= 2 )); then
    log_ok "Zertifikatskette enthält ${CERT_COUNT} Zertifikate"
else
    log_warn "Nur ein Zertifikat in ${CERT_FULLCHAIN} – iOS/Android brauchen die Kette (Fullchain)."
fi
PUB_CERT="$($SUDO openssl x509 -in "$CERT_FULLCHAIN" -noout -pubkey | sha256sum)"
PUB_KEY="$($SUDO openssl pkey -in "$CERT_KEY" -pubout 2>/dev/null | sha256sum)"
[[ "$PUB_CERT" == "$PUB_KEY" ]] || fail "Schlüssel passt nicht zum Zertifikat (CERT_FULLCHAIN/CERT_KEY prüfen)."
log_ok "Schlüssel passt zum Zertifikat"
$SUDO openssl x509 -in "$CERT_FULLCHAIN" -noout -checkend 0 >/dev/null || fail "Zertifikat ist abgelaufen."
SAN="$($SUDO openssl x509 -in "$CERT_FULLCHAIN" -noout -ext subjectAltName 2>/dev/null)"
for h in $SERVER_NAMES; do
    if grep -qF "DNS:${h}" <<<"$SAN"; then log_ok "SAN enthält ${h}"
    else log_warn "SAN enthält ${h} NICHT – Zertifikatswarnung unter diesem Namen."; fi
done

# ---------- Schritt 5: Relution-Vorlagen laden und anpassen ----------
log_step "Relution-Vorlagen laden und anpassen"

WORK_DIR="$(mktemp -d)"
run "application.yml geladen" curl -fsSL "${SETUP_URL}/application.yml" -o "${WORK_DIR}/application.yml"
run "relution-nginx.conf geladen" curl -fsSL "${SETUP_URL}/relution-nginx.conf" -o "${WORK_DIR}/relution-nginx.conf"

APP_YML="${WORK_DIR}/application.yml"
sed -i -e "s#%EXT_HOSTNAME_URL%#https://${EXT_HOSTNAME}#g" -e "s#%SYSTEM_ADMIN_EMAIL%#${ADMIN_EMAIL}#g" "$APP_YML"
sed -i -E "s#jdbc:postgresql://[^/?\"'[:space:]]+#jdbc:postgresql://${DB_HOST}:5432#" "$APP_YML"
grep -q "jdbc:postgresql://${DB_HOST}:5432" "$APP_YML" \
    || fail "JDBC-URL in application.yml nicht gefunden – Template hat sich geändert, Datenbank-Block manuell setzen."
log_ok "Externe URL, Admin-Mail und Datenbank-Host gesetzt"

if grep -Eq '^[[:space:]]+storage:' "$APP_YML"; then
    fail "application.yml enthält bereits 'storage:' – S3-Block manuell unter 'relution:' ergänzen (Relution-Doku: Connect object storage)."
fi
grep -A1 '^relution:' "$APP_YML" | tail -n 1 | grep -Eq '^  [A-Za-z]' \
    || fail "Unerwartete Einrückung unter 'relution:' – S3-Block manuell ergänzen."
run "S3-Block ergänzt (Keys als Secret-Platzhalter)" patch_storage "$APP_YML"
grep -q 'customEndpoint: http://' "$APP_YML" || fail "S3-Block wurde nicht eingefügt."
if grep -Eq '%[A-Z_]+%' "$APP_YML"; then
    fail "Unersetzte Platzhalter in application.yml: $(grep -Eo '%[A-Z_]+%' "$APP_YML" | sort -u | tr '\n' ' ')"
fi
# shellcheck disable=SC2016  # Literal \${…} gewollt
grep -q '\${postgres_password}' "$APP_YML" \
    || log_warn "application.yml nutzt nicht \${postgres_password} – Secret-Anbindung im Template prüfen."

NGX="${WORK_DIR}/relution-nginx.conf"
sed -i -E "s/server_name[^;]*;/server_name ${SERVER_NAMES};/g" "$NGX"
grep -q "server_name ${SERVER_NAMES};" "$NGX" || fail "server_name in relution-nginx.conf nicht gefunden – Template hat sich geändert."
log_ok "nginx: server_name ${SERVER_NAMES}"
grep -q 'X-Forwarded-Proto' "$NGX"   || log_warn "nginx-Template setzt kein X-Forwarded-Proto – Login kann scheitern."
# Upload-Limit: nginx-Standard (1 MB) bzw. Template-Wert reicht für App-Pakete nicht -> 413
if grep -q 'client_max_body_size' "$NGX"; then
    sed -i -E "s/client_max_body_size[^;]*;/client_max_body_size ${MAX_UPLOAD};/g" "$NGX"
else
    sed -i -E "s/^([[:space:]]*)(server_name[^;]*;)/\1\2\n\1client_max_body_size ${MAX_UPLOAD};/" "$NGX"
fi
grep -q "client_max_body_size ${MAX_UPLOAD};" "$NGX" || fail "client_max_body_size konnte nicht gesetzt werden – relution-nginx.conf manuell anpassen."
log_ok "nginx: Upload-Limit ${MAX_UPLOAD} (client_max_body_size)"

# ---------- Schritt 6: Secrets, Zertifikate, compose.yaml ----------
log_step "Secrets, Zertifikate und compose.yaml schreiben"

run "Verzeichnis ${BASE_DIR}" $SUDO install -d -m 0755 "$BASE_DIR"
run "Verzeichnis ${BASE_DIR}/secrets" $SUDO install -d -m 0700 "${BASE_DIR}/secrets"
for f in compose.yaml application.yml relution-nginx.conf; do
    if [[ -f "${BASE_DIR}/${f}" ]]; then $SUDO cp -a "${BASE_DIR}/${f}" "${BASE_DIR}/${f}.bak"; fi
done

run "Image ${RELUTION_IMAGE} geladen" $SUDO docker pull "$RELUTION_IMAGE"
run "Image nginx:stable geladen" $SUDO docker pull nginx:stable
RUID="$($SUDO docker run --rm --entrypoint id "$RELUTION_IMAGE" -u 2>/dev/null)"
[[ "$RUID" =~ ^[0-9]+$ ]] || fail "UID des Relution-Containers nicht ermittelbar (Ausgabe: '${RUID}')."
log_ok "Relution läuft im Container als UID ${RUID}"

if $SUDO test -s "${BASE_DIR}/secrets/system_admin_password"; then
    log_ok "Vorhandenes Admin-Passwort bleibt erhalten"
else
    # shellcheck disable=SC2034  # indirekt über write_secret genutzt
    ADMIN_PASSWORD="$(gen_secret 32)"
    run "Secret system_admin_password" write_secret system_admin_password ADMIN_PASSWORD
fi
run "Secret postgres_password" write_secret postgres_password DB_PASSWORD
run "Secret s3_access_key" write_secret s3_access_key S3_ACCESS_KEY
run "Secret s3_secret_key" write_secret s3_secret_key S3_SECRET_KEY
run "Secrets gehören UID ${RUID}" $SUDO chown "$RUID" "${BASE_DIR}/secrets/system_admin_password"

run "Zertifikat (Fullchain) -> server.pem" $SUDO install -m 0644 "$CERT_FULLCHAIN" "${BASE_DIR}/server.pem"
run "Schlüssel -> server.key" $SUDO install -m 0600 "$CERT_KEY" "${BASE_DIR}/server.key"

TMP_FILE="$APP_YML"
run "application.yml installiert" write_file 0644 "${BASE_DIR}/application.yml"
TMP_FILE="$NGX"
run "relution-nginx.conf installiert" write_file 0644 "${BASE_DIR}/relution-nginx.conf"

JAVA_PROXY=""
JAVA_NONPROXY="localhost|127.0.0.1|${DB_HOST}|${FS_HOST}"
for d in ${NO_PROXY_EXTRA//,/ }; do   # ".example.de" -> "*.example.de" (Java-Syntax)
    if [[ "$d" == .* ]]; then JAVA_NONPROXY+="|*${d}"; else JAVA_NONPROXY+="|${d}"; fi
done
if [[ -n "$PROXY_URL" ]]; then
    JAVA_PROXY="      JAVA_TOOL_OPTIONS: >-
        -Dhttp.proxyHost=${PROXY_HOST} -Dhttp.proxyPort=${PROXY_PORT}
        -Dhttps.proxyHost=${PROXY_HOST} -Dhttps.proxyPort=${PROXY_PORT}
        -Dhttp.nonProxyHosts=${JAVA_NONPROXY}"
fi

TMP_FILE="${WORK_DIR}/compose.yaml"
cat > "$TMP_FILE" <<EOF
# Relution – erzeugt durch ${SCRIPT_NAME}.sh
# Keine Zugangsdaten im Klartext: alles über ./secrets/
services:
  relution:
    image: ${RELUTION_IMAGE}
    restart: unless-stopped
    container_name: relution
    environment:
      TZ: "Europe/Berlin"
${JAVA_PROXY}
    secrets:
      - postgres_password
      - system_admin_password
      - s3_access_key
      - s3_secret_key
    expose:
      - '8080'
      - '8099'
    volumes:
      - './application.yml:/opt/relution/application.yml'
    networks:
      - reverse-proxy

  nginx:
    image: nginx:stable
    restart: unless-stopped
    container_name: nginx
    depends_on:
      - relution
    environment:
      TZ: "Europe/Berlin"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "./relution-nginx.conf:/etc/nginx/conf.d/relution-nginx.conf:ro"
      - "./server.pem:/etc/nginx/server.pem:ro"
      - "./server.key:/etc/nginx/server.key:ro"
    networks:
      - reverse-proxy

secrets:
  postgres_password:
    file: ./secrets/postgres_password
  system_admin_password:
    file: ./secrets/system_admin_password
  s3_access_key:
    file: ./secrets/s3_access_key
  s3_secret_key:
    file: ./secrets/s3_secret_key

networks:
  reverse-proxy: {}
EOF
run "compose.yaml installiert" write_file 0644 "${BASE_DIR}/compose.yaml"
rm -rf "$WORK_DIR"

run "compose.yaml validiert" $SUDO docker compose --project-directory "$BASE_DIR" config -q

# ---------- Schritt 7: Relution starten ----------
log_step "Relution starten (erster Start legt das Datenbankschema an)"

run "Container gestartet" $SUDO docker compose --project-directory "$BASE_DIR" up -d

echo -e "  Warte auf Relution (max. $((START_TIMEOUT / 60)) Minuten) …"
STARTED=""
for ((t = 0; t < START_TIMEOUT; t += 10)); do
    if $SUDO docker logs relution 2>&1 | grep -q 'APPLICATION FAILED TO START'; then
        echo -e "${C_YELLOW}  --- Relution-Log (Auszug) ---${C_RESET}"
        $SUDO docker logs relution 2>&1 | grep -A 12 'APPLICATION FAILED TO START' | sed 's/^/    /'
        fail "Relution startet nicht – Ursache im Relution-Log-Auszug oben (häufig: Secret-Rechte, DB-Passwort, S3-Rechte)."
    fi
    case "$(http_code)" in
        200|301|302|303|401) STARTED=1; break ;;
    esac
    sleep 10
done
[[ -n "$STARTED" ]] || fail "Keine Antwort nach ${START_TIMEOUT}s – 'docker logs -f relution' prüfen."
log_ok "Relution antwortet über nginx (HTTPS ${EXT_HOSTNAME})"

if $SUDO docker logs relution 2>&1 | grep -qiE "Failed to bind properties under 'relution\.storage"; then
    fail "S3-Konfiguration wird nicht gelesen – Secrets s3_access_key/s3_secret_key prüfen."
fi
if $SUDO docker exec relution env 2>/dev/null | grep -qi 'RELUTION_STORAGE'; then
    log_warn "RELUTION_STORAGE_*-Variablen im Container – überschreiben die application.yml."
fi

# ---------- Schritt 8: Zusammenfassung ----------
log_step "Zusammenfassung"

log_ok "Relution: $($SUDO docker inspect -f '{{.Config.Image}} – {{.State.Status}}' relution 2>/dev/null)"
log_ok "Geräte/Portal: https://${EXT_HOSTNAME}${PORTAL_HOSTNAME:+  ·  Portal intern: https://${PORTAL_HOSTNAME}}"
log_ok "Login: admin / Passwort in ${BASE_DIR}/secrets/system_admin_password (root)"
log_warn "Admin-Passwort nach dem ersten Login ändern."
log_warn "Funktionstest: App > 512 KB hochladen -> Objekt muss im Bucket '${S3_BUCKET}' erscheinen."
log_warn "Danach Image auf die laufende Version pinnen (statt :latest), siehe 'docker inspect relution'."
echo -e "\n${C_GREEN}${C_BOLD}Relution-Installation erfolgreich abgeschlossen!${C_RESET}"

exit 0
