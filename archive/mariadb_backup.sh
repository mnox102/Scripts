#!/bin/bash

set -euo pipefail  # Fehlerbehandlung aktivieren

# Serverspezifische Variablen
LOCATION_NAME="Jugendwerk_Landau"
PASSWORD="RmmZ?MmC1dKdSs!"
RELUTION_CONTAINER=("relution")

# Ggf. anzupassen
BACKUP_DIR="/media/backup"
CONFIG_BACKUP_DIR="/media/backup_cnfg"
SOURCE="/media/new_backup"
MARIADB_CONTAINER="docker_mariadb"
FTP_SCRIPT="/usr/local/bin/lftpmirror.sh"

# Allgemeine Variablen
RELUTION_COMPOSE_FILE="/opt/relution/docker-compose.yml"
RETENTION_DAYS=5
DATE=$(date +"%Y-%m-%d")
TIMESTAMP=$(date +%F_%T)
BACKUP_NAME="backup_${LOCATION_NAME}_$DATE"
DEST="$BACKUP_DIR/$BACKUP_NAME.tar.gz"
DEST_CONFIG="$CONFIG_BACKUP_DIR/$BACKUP_NAME"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

log "MariaDB Backup Skript startet um $TIMESTAMP"

# Relution stoppen
log "Stoppe Relution Container"
for container in "${RELUTION_CONTAINER[@]}"; do
	docker compose -f "$RELUTION_COMPOSE_FILE" stop $container
	log "Container $container stoppt"
done
log "Warte 30s bis Relution heruntergefahren ist"
#sleep 30

# Datenbank-Backup durchführen
log "Erstelle MariaDB Backup"
docker exec -i "$MARIADB_CONTAINER" mariabackup --backup --target-dir="$SOURCE" --user=root --password=$PASSWORD

# Backup packen und bereinigen
log "Packe Backup nach $DEST"
tar -zcvPf "$DEST" "$SOURCE"

if [[ -f "$DEST" ]]; then
    log "Backup wurde erfolgreich gepackt und komprimiert"
    rm -rf "$SOURCE"
    log "Ungepacktes Backup wurde gelöscht"
else
    log "FEHLER: Backup wurde NICHT gepackt und komprimiert"
    exit 1
fi

# Relution starten
log "Starte Relution Container"
for container in "${RELUTION_CONTAINER[@]}"; do
	docker compose -f "$RELUTION_COMPOSE_FILE" start $container
	log "Container $container startet"
done

# Alte Backups löschen
log "Lösche alte Backups (> $RETENTION_DAYS Tage)"
find "$BACKUP_DIR" -name "backup_${LOCATION_NAME}_*.tar.gz" -type f -mtime +$RETENTION_DAYS -exec rm -v {} \;



# Konfigurationsdateien sichern
mkdir -p "$DEST_CONFIG"
cp /opt/relution/application.yml "$DEST_CONFIG/application.yml"
cp "$RELUTION_COMPOSE_FILE" "$DEST_CONFIG/docker-compose.yml"
log "Konfigurationsdateien gesichert"

# Alte Konfigurationsdateien löschen
log "Lösche alte Konfigurationsdateien (> $RETENTION_DAYS Tage)"
find "$CONFIG_BACKUP_DIR" -name "backup_${LOCATION_NAME}_*" -type f -mtime +$RETENTION_DAYS -exec rm -rfv {} \;


# FTP Sync durchführen
if [[ -f $FTP_SCRIPT ]]; then
	log "Starte FTP Sync"
	sudo lftp -f "$FTP_SCRIPT"
	log "FTP Sync abgeschlossen"
else
	log "Kein FTP Synch eingerichtet"
fi

# Nginx nach 5 Minuten neustarten
log "Warte 300 Sekunden, bevor Nginx neugestartet wird"
sleep 300
docker compose -f "$RELUTION_COMPOSE_FILE" restart nginx
log "Nginx wurde neugestartet"

# Docker bereinigen
log "Bereinige unbenutzte Docker Images und Volumes"
docker image prune -a -f
docker volume prune -f
log "Skript abgeschlossen"
