#!/usr/bin/env bash

# Installiert sudo auf Debian nach und fügt optional einen Benutzer
# zur Gruppe "sudo" hinzu.
# Muss als root ausgeführt werden.

set -euo pipefail

# --- 1. Rootrechte prüfen ---------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo "Fehler: Dieses Skript muss als root ausgeführt werden." >&2
    echo "Beispiel:  su -   dann  ./setup-sudo.sh" >&2
    exit 1
fi

# --- 2. sudo installieren, falls nicht vorhanden ----------------------------
if command -v sudo >/dev/null 2>&1; then
    echo "sudo ist bereits installiert ($(sudo --version | head -n1))."
else
    echo "sudo nicht gefunden. Installiere sudo ..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y sudo
    echo "sudo wurde installiert."
fi

# --- 3. Rückfrage: Benutzer zur sudo-Gruppe hinzufügen? ---------------------
read -r -p "Möchtest du einen Benutzer zur sudo-Gruppe hinzufügen? [j/N] " antwort
case "${antwort}" in
    [jJyY])
        read -r -p "Benutzername: " benutzer

        if [[ -z "${benutzer}" ]]; then
            echo "Kein Benutzername eingegeben. Abbruch." >&2
            exit 1
        fi

        # Existiert der Benutzer?
        if ! id "${benutzer}" >/dev/null 2>&1; then
            echo "Fehler: Benutzer '${benutzer}' existiert nicht." >&2
            exit 1
        fi

        # Ist er bereits in der Gruppe?
        if id -nG "${benutzer}" | tr ' ' '\n' | grep -qx "sudo"; then
            echo "Benutzer '${benutzer}' ist bereits in der Gruppe sudo."
        else
            usermod -aG sudo "${benutzer}"
            echo "Benutzer '${benutzer}' wurde zur Gruppe sudo hinzugefügt."
            echo "Hinweis: Er muss sich neu anmelden, damit die Gruppe greift."
        fi
        ;;
    *)
        echo "Kein Benutzer hinzugefügt. Fertig."
        ;;
esac
