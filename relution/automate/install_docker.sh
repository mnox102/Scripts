#!/usr/bin/env bash

# Automatisierte Installation von Docker Engine + Docker Compose Plugin
# auf Ubuntu über das offizielle apt-Repository, wie beschrieben unter:
# https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository
# Mit Statusanzeige und Fehlerprüfung nach jedem Schritt.

set -uo pipefail

# ---------- Farben / Formatierung ----------
readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_GREEN='\033[0;32m'
readonly C_RED='\033[0;31m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'

STEP_NUM=0
TOTAL_STEPS=8

log_step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo -e "\n${C_BOLD}${C_BLUE}[${STEP_NUM}/${TOTAL_STEPS}]${C_RESET} ${C_BOLD}$1${C_RESET}"
}

log_ok() {
    echo -e "  ${C_GREEN}✔${C_RESET} $1"
}

log_err() {
    echo -e "  ${C_RED}✘${C_RESET} $1"
}

log_warn() {
    echo -e "  ${C_YELLOW}⚠${C_RESET} $1"
}

fail() {
    log_err "$1"
    echo -e "\n${C_RED}${C_BOLD}Installation abgebrochen.${C_RESET}"
    exit 1
}

# Führt einen Befehl aus und prüft den Exit-Code
run() {
    local desc="$1"
    shift
    if "$@" >/tmp/install-docker.log 2>&1; then
        log_ok "$desc"
        return 0
    else
        log_err "$desc"
        echo -e "${C_YELLOW}  --- Letzte Log-Zeilen ---${C_RESET}"
        tail -n 15 /tmp/install-docker.log | sed 's/^/    /'
        fail "Befehl fehlgeschlagen: $*"
    fi
}

# ---------- Vorprüfungen ----------

echo -e "${C_BOLD}Docker Engine Installation für Ubuntu${C_RESET}"
echo "Basierend auf: https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository"

# Root-Check
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    if ! command -v sudo &>/dev/null; then
        fail "Dieses Skript benötigt root-Rechte oder sudo. Keines von beiden gefunden."
    fi
    SUDO="sudo"
fi

# OS-Check
if [[ ! -f /etc/os-release ]]; then
    fail "/etc/os-release nicht gefunden — dies scheint kein Ubuntu/Debian-basiertes System zu sein."
fi
# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
    log_warn "Erkanntes System ist '${ID:-unbekannt}', kein Ubuntu. Das Skript setzt Ubuntu voraus."
fi
log_ok "System erkannt: ${PRETTY_NAME:-unbekannt}"

# Bereits installiert?
if command -v docker &>/dev/null; then
    log_warn "Docker scheint bereits installiert zu sein: $(docker --version 2>/dev/null || echo 'Version unbekannt')"
    read -r -p "  Trotzdem fortfahren? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo "Abgebrochen."
        exit 0
    fi
fi

# ---------- Schritt 1: Alte/konfliktende Pakete entfernen ----------
log_step "Entferne konfliktende/alte Docker-Pakete"

CONFLICT_PKGS="docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc"
INSTALLED_CONFLICTS=$(dpkg --get-selections $CONFLICT_PKGS 2>/dev/null | awk '{print $1}' || true)

if [[ -n "$INSTALLED_CONFLICTS" ]]; then
    # shellcheck disable=SC2086
    run "Konfliktende Pakete entfernt ($INSTALLED_CONFLICTS)" $SUDO apt-get remove -y $INSTALLED_CONFLICTS
else
    log_ok "Keine konfliktenden Pakete gefunden"
fi

# ---------- Schritt 2: apt aktualisieren + Voraussetzungen ----------
log_step "Aktualisiere apt und installiere Voraussetzungen"

run "apt update" $SUDO apt-get update
run "ca-certificates und curl installiert" $SUDO apt-get install -y ca-certificates curl

# ---------- Schritt 3: Keyring-Verzeichnis + GPG-Key ----------
log_step "Richte Docker GPG-Key ein"

run "Verzeichnis /etc/apt/keyrings angelegt" $SUDO install -m 0755 -d /etc/apt/keyrings

if $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; then
    log_ok "GPG-Key heruntergeladen"
else
    fail "Download des GPG-Keys fehlgeschlagen"
fi

run "Leserechte für GPG-Key gesetzt" $SUDO chmod a+r /etc/apt/keyrings/docker.asc

# ---------- Schritt 4: apt-Repository einrichten ----------
log_step "Richte Docker apt-Repository ein"

CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
ARCH="$(dpkg --print-architecture)"

if [[ -z "$CODENAME" ]]; then
    fail "Konnte Ubuntu-Codename nicht ermitteln"
fi

REPO_FILE="/etc/apt/sources.list.d/docker.sources"
TMP_REPO_FILE="$(mktemp)"

cat > "$TMP_REPO_FILE" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

if $SUDO cp "$TMP_REPO_FILE" "$REPO_FILE"; then
    log_ok "Repository-Datei geschrieben (${CODENAME}, ${ARCH})"
else
    fail "Konnte ${REPO_FILE} nicht schreiben"
fi
rm -f "$TMP_REPO_FILE"

run "apt update (mit neuem Repository)" $SUDO apt-get update

# ---------- Schritt 5: Docker-Pakete installieren ----------
log_step "Installiere Docker Engine, CLI, containerd und Compose-Plugin"

run "Docker-Pakete installiert" $SUDO apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# ---------- Schritt 6: Dienststatus prüfen ----------
log_step "Prüfe Docker-Dienst"

if $SUDO systemctl is-active --quiet docker; then
    log_ok "Docker-Dienst läuft"
else
    log_warn "Docker-Dienst läuft nicht, versuche Start..."
    run "Docker-Dienst gestartet" $SUDO systemctl start docker
fi

run "Docker-Dienst für Autostart aktiviert" $SUDO systemctl enable docker

# ---------- Schritt 7: hello-world Test ----------
log_step "Führe Funktionstest mit hello-world aus"

if $SUDO docker run --rm hello-world >/tmp/install-docker-hello.log 2>&1; then
    log_ok "hello-world Container erfolgreich ausgeführt"
else
    log_err "hello-world Test fehlgeschlagen"
    tail -n 15 /tmp/install-docker-hello.log | sed 's/^/    /'
    fail "Docker-Installation konnte nicht verifiziert werden"
fi

# ---------- Schritt 8: Zusammenfassung ----------
log_step "Zusammenfassung"

DOCKER_VERSION="$(docker --version 2>/dev/null || echo 'unbekannt')"
COMPOSE_VERSION="$($SUDO docker compose version 2>/dev/null || echo 'unbekannt')"

log_ok "Docker Engine: ${DOCKER_VERSION}"
log_ok "Docker Compose: ${COMPOSE_VERSION}"

echo -e "\n${C_GREEN}${C_BOLD}Docker wurde erfolgreich installiert!${C_RESET}"

if ! getent group docker >/dev/null 2>&1 || [[ -z "$(getent group docker | cut -d: -f4)" ]]; then
    echo -e "${C_YELLOW}Hinweis:${C_RESET} Die Gruppe 'docker' enthält keine Benutzer, daher ist derzeit"
    echo "sudo für Docker-Befehle erforderlich. Um dies zu ändern:"
    echo -e "  ${C_BOLD}sudo usermod -aG docker \$USER${C_RESET}  (danach neu anmelden)"
fi

exit 0
