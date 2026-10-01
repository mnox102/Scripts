#!/usr/bin/env bash

# Automatisierte Installation von Docker Engine + Docker Compose Plugin
# auf Ubuntu oder Debian (inkl. Derivate) über das offizielle apt-Repository:
#   https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository
#   https://docs.docker.com/engine/install/debian/#install-using-the-repository
# Mit automatischer Distributionserkennung, Statusanzeige und Fehlerprüfung.

set -uo pipefail

# ---------- Farben / Formatierung ----------
readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_GREEN='\033[0;32m'
readonly C_RED='\033[0;31m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'

readonly LOG_FILE="/tmp/install-docker.log"
: > "$LOG_FILE"

STEP_NUM=0
TOTAL_STEPS=8

log_step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo -e "\n${C_BOLD}${C_BLUE}[${STEP_NUM}/${TOTAL_STEPS}]${C_RESET} ${C_BOLD}$1${C_RESET}"
}

log_ok()   { echo -e "  ${C_GREEN}✔${C_RESET} $1"; }
log_err()  { echo -e "  ${C_RED}✘${C_RESET} $1"; }
log_warn() { echo -e "  ${C_YELLOW}⚠${C_RESET} $1"; }

fail() {
    log_err "$1"
    echo -e "\n${C_RED}${C_BOLD}Installation abgebrochen.${C_RESET} Log: ${LOG_FILE}"
    exit 1
}

# Führt einen Befehl aus und prüft den Exit-Code (Log wird angehängt, nicht überschrieben)
run() {
    local desc="$1"
    shift
    echo "### $desc: $*" >>"$LOG_FILE"
    if "$@" >>"$LOG_FILE" 2>&1; then
        log_ok "$desc"
        return 0
    else
        log_err "$desc"
        echo -e "${C_YELLOW}  --- Letzte Log-Zeilen ---${C_RESET}"
        tail -n 15 "$LOG_FILE" | sed 's/^/    /'
        fail "Befehl fehlgeschlagen: $*"
    fi
}

# ---------- Distributionserkennung ----------
# Setzt: DOCKER_DISTRO (ubuntu|debian), CODENAME, CONFLICT_PKGS
detect_distro() {
    if [[ ! -f /etc/os-release ]]; then
        fail "/etc/os-release nicht gefunden — kein Ubuntu/Debian-basiertes System."
    fi
    # shellcheck disable=SC1091
    . /etc/os-release

    local id="${ID:-}"
    local id_like="${ID_LIKE:-}"

    case "$id" in
        ubuntu)
            DOCKER_DISTRO="ubuntu"
            ;;
        debian)
            DOCKER_DISTRO="debian"
            ;;
        *)
            # Derivate: Ubuntu zuerst prüfen (Mint/Pop!_OS haben ID_LIKE="ubuntu debian")
            if [[ " $id_like " == *" ubuntu "* ]]; then
                DOCKER_DISTRO="ubuntu"
            elif [[ " $id_like " == *" debian "* ]]; then
                DOCKER_DISTRO="debian"
            else
                fail "Nicht unterstütztes System: '${id:-unbekannt}' (ID_LIKE='${id_like}'). Nur Ubuntu/Debian."
            fi
            log_warn "Derivat erkannt ('${id}') — verwende Docker-Repository für ${DOCKER_DISTRO}."
            ;;
    esac

    # Codename: Bei Ubuntu-Derivaten steht der Ubuntu-Codename in UBUNTU_CODENAME,
    # VERSION_CODENAME wäre dort z.B. der Mint-Codename und im Docker-Repo unbekannt.
    if [[ "$DOCKER_DISTRO" == "ubuntu" ]]; then
        CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    else
        CODENAME="${VERSION_CODENAME:-}"
    fi
    [[ -n "$CODENAME" ]] || fail "Konnte Codename für ${DOCKER_DISTRO} nicht ermitteln (VERSION_CODENAME leer)."

    # Konfliktpakete laut offizieller Doku je Distribution
    if [[ "$DOCKER_DISTRO" == "ubuntu" ]]; then
        CONFLICT_PKGS="docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc"
    else
        CONFLICT_PKGS="docker.io docker-compose docker-doc podman-docker containerd runc"
    fi

    DOCKER_REPO_URL="https://download.docker.com/linux/${DOCKER_DISTRO}"

    log_ok "System erkannt: ${PRETTY_NAME:-$id} → Docker-Repo: ${DOCKER_DISTRO}/${CODENAME}"
}

# ---------- Vorprüfungen ----------

echo -e "${C_BOLD}Docker Engine Installation für Ubuntu/Debian${C_RESET}"

# Root-Check
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    command -v sudo &>/dev/null || fail "Dieses Skript benötigt root-Rechte oder sudo. Keines von beiden gefunden."
    SUDO="sudo"
fi

detect_distro

# Bereits installiert?
if command -v docker &>/dev/null; then
    log_warn "Docker scheint bereits installiert zu sein: $(docker --version 2>/dev/null || echo 'Version unbekannt')"
    if [[ -t 0 ]]; then
        read -r -p "  Trotzdem fortfahren? [y/N] " confirm
    else
        confirm="n"
        log_warn "Keine interaktive Eingabe möglich — breche ab."
    fi
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo "Abgebrochen."
        exit 0
    fi
fi

# ---------- Schritt 1: Alte/konfliktende Pakete entfernen ----------
log_step "Entferne konfliktende/alte Docker-Pakete"

# shellcheck disable=SC2086
INSTALLED_CONFLICTS=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n' $CONFLICT_PKGS 2>/dev/null \
    | awk '$2=="installed"{print $1}' | xargs || true)

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
run "GPG-Key heruntergeladen (${DOCKER_DISTRO})" \
    $SUDO curl -fsSL "${DOCKER_REPO_URL}/gpg" -o /etc/apt/keyrings/docker.asc
run "Leserechte für GPG-Key gesetzt" $SUDO chmod a+r /etc/apt/keyrings/docker.asc

# ---------- Schritt 4: apt-Repository einrichten ----------
log_step "Richte Docker apt-Repository ein"

ARCH="$(dpkg --print-architecture)"

# Prüfen, ob Docker diesen Codename überhaupt anbietet (fängt z.B. Kali, Debian sid,
# brandneue Releases ab, bevor apt mit einer kryptischen Meldung scheitert)
if curl -fsSI "${DOCKER_REPO_URL}/dists/${CODENAME}/Release" >/dev/null 2>&1; then
    log_ok "Codename '${CODENAME}' wird von Docker unterstützt"
else
    fail "Docker bietet kein Repository für '${DOCKER_DISTRO}/${CODENAME}' an. Siehe ${DOCKER_REPO_URL}/dists/"
fi

REPO_FILE="/etc/apt/sources.list.d/docker.sources"
TMP_REPO_FILE="$(mktemp)"

cat > "$TMP_REPO_FILE" <<EOF
Types: deb
URIs: ${DOCKER_REPO_URL}
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

if $SUDO install -m 0644 "$TMP_REPO_FILE" "$REPO_FILE"; then
    log_ok "Repository-Datei geschrieben (${DOCKER_DISTRO}/${CODENAME}, ${ARCH})"
else
    rm -f "$TMP_REPO_FILE"
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

run "hello-world Container erfolgreich ausgeführt" $SUDO docker run --rm hello-world

# ---------- Schritt 8: Zusammenfassung ----------
log_step "Zusammenfassung"

log_ok "Distribution: ${DOCKER_DISTRO} (${CODENAME}, ${ARCH})"
log_ok "Docker Engine: $(docker --version 2>/dev/null || echo 'unbekannt')"
log_ok "Docker Compose: $($SUDO docker compose version 2>/dev/null || echo 'unbekannt')"

echo -e "\n${C_GREEN}${C_BOLD}Docker wurde erfolgreich installiert!${C_RESET}"

if [[ -z "$(getent group docker 2>/dev/null | cut -d: -f4)" ]]; then
    echo -e "${C_YELLOW}Hinweis:${C_RESET} Die Gruppe 'docker' enthält keine Benutzer, daher ist derzeit"
    echo "sudo für Docker-Befehle erforderlich. Um dies zu ändern:"
    echo -e "  ${C_BOLD}sudo usermod -aG docker \$USER${C_RESET}  (danach neu anmelden)"
fi

exit 0
