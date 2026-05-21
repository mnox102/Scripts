#!/bin/bash

# minio-Backup-Script auf Strato S3
# mc alias für root setzen

LOGFILE="/var/log/minio-strato-backup.log"
DATE=$(date "+%Y-%m-%d %H:%M:%S")

echo "[$DATE] Backup gestartet" >> $LOGFILE

# unter almalinux:
# /usr/local/bin/mc mirror --overwrite --remove localminio/relution strato/ANPASSEN >> $LOGFILE 2>&1
mc mirror --overwrite --remove localminio/relution strato/ANPASSEN >> $LOGFILE 2>&1

if [ $? -eq 0 ]; then
echo "[$DATE] Backup erfolgreich" >> $LOGFILE
else
echo "[$DATE] FEHLER beim Backup!" >> $LOGFILE
fi

echo "-----------------------------" >> $LOGFILE
