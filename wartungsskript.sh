#!/bin/bash

# Dieses Skript wurde für das Betriebssystem Ubuntu geschrieben und kann in einzelnen Teilen auf anderen Distributionen nicht funktionieren
# Es muss zum prüfen der Relution Version die Abfrage im Skript angepasst werden
## Einzustellende Variablen

serverurl="relution.jugendwerk-landau.de"
backupname="Jugendwerk_Landau"

# Zu überprüfende Docker-Container
docker_containers=("mariadb" "relution" "nginx")
MARIADB_CONTAINER="docker_mariadb"
RELUTION_CONTAINER="docker_relution"

# Zu überprüfende Dienste
services_list=("cron" "ufw" "postfix" "docker")

# Verzeichnisse definieren
log_dir="/opt/wartung"
backup_dir="/media/backup"


## Allgemeine Variablen

# Datum für Logdateien
date=$(date +"%Y-%m-%d")
#Hostname
name=$(hostname)

# Verzeichnisse
log_file="$log_dir/log_$date"
error_log_file="$log_dir/log_${date}_ERROR"

# Backup-Einstellungen
backup_prefix="backup_${backupname}_"
backup_days=10
cleanup_days=21
cleanup_limit=42
old_backups=false

# Log-Verzeichnis erstellen, falls nicht vorhanden
mkdir -p "$log_dir"

# Funktion für Logging
log() {
    echo -e "$1" >> "$log_file"
}

log_error() {
    echo -e "$1" >> "$error_log_file"
}

# Funktion zur Ermittlung des Service-Managers
get_servicectl() {
    local servicename=$1
    if command -v systemctl &>/dev\null && systemctl is-active --quiet "$servicename"; then
        echo "SYSTEMCTL"
    elif command -v service &>/dev\null && service --status-all | grep -Fq "$servicename"; then
        echo "SERVICE"
    elif [[ -f /etc/init.d/$servicename ]]; then
        echo "INIT.D"
    else
        echo "UNKNOWN"
    fi
}

# Funktion zur Steuerung von Services
servicectl() {
    local servicectl=$1
    local command=$2
    local servicename=$3

    case "$servicectl" in
        SYSTEMCTL) systemctl "$command" "$servicename" ;;
        SERVICE) service "$servicename" "$command" ;;
        INIT.D) /etc/init.d/"$servicename" "$command" ;;
        *) log "Unbekannter Service-Manager für $servicename" ;;
    esac
}

# Funktion zur Überprüfung von Backups
check_backups() {
    local found=0
    for ((i = 0; i < backup_days; i++)); do
        local backup_date=$(date -d "$i days ago" +"%Y-%m-%d")
        local backup_file="$backup_dir/${backup_prefix}${backup_date}.tar.gz"

        if [[ -f "$backup_file" ]]; then
            ((found++))
        else
            log "Backup fehlt: $backup_file"
        fi
    done

    if [[ $found -eq $backup_days ]]; then
        log "Alle $backup_days Backups sind vorhanden."
    else
        log "Nur $found von $backup_days Backups vorhanden."
    fi
}

# Funktion zur Überprüfung und Löschung alter Backups
cleanup_old_backups() {
	log "\n----------------------------------------"
    log "Überprüfung nicht gelöschter Backups:"
	log "----------------------------------------"
    for ((i = cleanup_days; i < cleanup_limit; i++)); do
        local backup_date=$(date -d "$i days ago" +"%Y-%m-%d")
        ls "$backup_dir" | grep "${backup_prefix}${backup_date}.tar.gz" >> "$log_file"
		if [[ -f ${backup_dir}${backup_prefix}${backup_date}.tar.gz ]]; then
			old_backups = true
		fi
    done
	if [[ "$old_backups" = "false" ]]; then
		log "Keine Backups älter als $cleanup_days Tage gefunden"
	fi
}

# Funktion zur Protokollierung von Logs
scrape_logs() {
    local search_word=$1
    local log_command=$2
    local log_variable=$3
    local entry_count=$($log_command $log_variable | grep -c "$search_word")

    if (( entry_count == 0 )); then
        log "Keine Probleme gefunden"
    elif (( entry_count < 20 )); then
        $log_command $log_variable | grep "$search_word" >> "$log_file"
    else
        log_error "$search_word Fehler Log (${entry_count} Einträge):"
        $log_command $log_variable | grep "$search_word" >> "$error_log_file"
        log "Letzte 10 Einträge zu $search_word:"
        $log_command $log_variable | grep "$search_word" | tail -n 10 >> "$log_file"
    fi
}

### START DER WARTUNG ###
log "----------------------------------------"
log "Wartungsbericht vom $date"
log "----------------------------------------"
log " "
log " "

# Kernel-Version
log "----------------------------------------"
log "Kernel Version:"
log "----------------------------------------"
uname -a >> "$log_file"

# Neustart erforderlich?
log "\n----------------------------------------"
log "System Neustart erforderlich?"
log "----------------------------------------"
if [ -x /etc/update-motd.d/98-reboot-required ]; then
    output=$( /etc/update-motd.d/98-reboot-required )
    if [[ -n "$output" ]]; then
        log "Der Server muss neu gestartet werden."
    else
        log "Kein Neustart erforderlich."
    fi
else
    log "Das Skript /etc/update-motd.d/98-reboot-required existiert nicht oder ist nicht ausführbar."
fi

# Docker-Status von relevanten Containern

if (( ${#docker_containers[@]} )); then
	log "\n----------------------------------------"
	log "Docker-Container Status:"
	log "----------------------------------------"
	for container in "${docker_containers[@]}"; do
		docker ps | grep "$container" >> "$log_file"
	done
fi
# Dienstprüfung
log "\n----------------------------------------"
log "Dienste Status:"
log "----------------------------------------"
if (( ${#services_list[@]} )); then
	for services in "${services_list[@]}"; do
		service_ctl=$(get_servicectl $services)
		log "$services :"
		servicectl $service_ctl status $services | grep Active >> "$log_file"
	done
else
	log "Keine Services definiert"
fi

# Zeitsynchronisation prüfen
log "\n----------------------------------------"
log "Server Zeit:"
log "----------------------------------------"
log "Cronjob wird um 03:01 Uhr ausgeführt"
timedatectl >> "$log_file"

# Relution-Version prüfen
log "\n----------------------------------------"
log "Relution Version:"
log "----------------------------------------"
if [ -z $RELUTION_CONTAINER ]; then
	cat /opt/relution/relution-package-info.json | grep version >> "$log_file"
else
	docker exec $RELUTION_CONTAINER cat /opt/relution/relution-package-info.json | grep version >> "$log_file"
fi

# MariaDB-Version prüfen
log "\n----------------------------------------"
log "MariaDB Version:"
log "----------------------------------------"
if [ -z $MARIADB_CONTAINER ]; then
	mariadb --version >> "$log_file"
else
	docker exec -i $MARIADB_CONTAINER mariadb --version >> "$log_file"
fi
# Server-Erreichbarkeit prüfen
log "\n----------------------------------------"
log "Ping-Test für $serverurl:"
log "----------------------------------------"
ping -c 4 "$serverurl" | grep -v PING | grep -v bytes >> "$log_file"

# Backup-Überprüfung
log "\n----------------------------------------"
log "Backup-Status:"
log "----------------------------------------"
check_backups
cleanup_old_backups

# System-Logs nach Neustarts durchsuchen
log "\n----------------------------------------"
log "Systemlog auf Systemstarts prüfen:"
log "----------------------------------------"
scrape_logs "Startup" "journalctl -r"

# Relution-Logs Fehler prüfen
log "\n----------------------------------------"
log "Relution Logs:"
log "----------------------------------------"
if [ -z $RELUTION_CONTAINER ]; then
	scrape_logs $name journalctl "-u relution -r --since yesterday -p 0..3"
else
	scrape_logs relution journalctl "-u docker -r --since yesterday -p 0..3"
fi

log "\n----------------------------------------"
log "Mail Logs:"
log "----------------------------------------"

scrape_logs $name journalctl "-u postfix -r --since yesterday -p 0..3"

# Netzwerkauslastung protokollieren
log "\n----------------------------------------"
log "Netzwerkauslastung:"
log "----------------------------------------"
vnstat -m >> "$log_file"

# Alte Logs löschen
log "\n----------------------------------------"
log "Lösche alte Logs (älter als $cleanup_days Tage):"
log "----------------------------------------"
for ((d = cleanup_days; d < cleanup_limit; d++)); do
    old_date=$(date -d "$d days ago" +"%Y-%m-%d")
    rm -f "$log_dir/log_$old_date" "$log_dir/log_${old_date}_ERROR"
done
log "Alte Logs gelöscht"

log "\n----------------------------------------"
log "Wartung abgeschlossen!"
log "----------------------------------------"
