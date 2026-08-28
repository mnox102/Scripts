#!/bin/bash

# Server Name angeben
server_name="Jugendwerk Landau"

# Ziel E-Mail-Adresse definieren
recipient_email="apple-support@rednet.ag"

# Ausgangsverzeichnis für die Logs
log_dir="/opt/wartung"

# Dateiname für die tar-Datei
tar_filename="$log_dir/logs_$(date +"%Y-%m-%d").tar.gz"

# Lösche vorherige tar-Datei, falls vorhanden
[ -f "$tar_filename" ] && rm "$tar_filename"

# Temporäres Verzeichnis für die Struktur der letzten 7 Tage
temp_dir=$(mktemp -d)

# Logs der letzten 7 Tage in das temporäre Verzeichnis kopieren
for i in {1..7}
do
    date=$(date -d "-$i day" +"%Y-%m-%d")
    day_dir="$temp_dir/$date"
    mkdir -p "$day_dir"
    
    log_file="$log_dir/log_$date"
    log_error_file="$log_dir/log_${date}_ERROR"
    log_ssh_file="$log_dir/log_${date}_SSH"
    
    [ -f "$log_file" ] && cp "$log_file" "$day_dir/"
    [ -f "$log_error_file" ] && cp "$log_error_file" "$day_dir/"
    [ -f "$log_ssh_file" ] && cp "$log_ssh_file" "$day_dir/"
done

# Erstellen der tar-Datei aus dem temporären Verzeichnis
tar -czvf "$tar_filename" -C "$temp_dir" .

# Temporäres Verzeichnis löschen
rm -rf "$temp_dir"

# Logs des aktuellen Tages
current_date=$(date +"%Y-%m-%d")
current_log_file="$log_dir/log_$current_date"
current_log_error_file="$log_dir/log_${current_date}_ERROR"
current_log_ssh_file="$log_dir/log_${current_date}_SSH"



# Nachrichtentext initialisieren
message=""

# Nachrichtentext aus dem aktuellen Log-File erstellen
if [ -f "$current_log_file" ]; then
    message=$(cat "$current_log_file")
else
    message="Kein Ergebnis des Wartungsskriptes gefunden!"
fi

# Anhangs-Array initialisieren
attachments=()

# Prüfen und Anhänge hinzufügen
[ -f "$current_log_error_file" ] && attachments+=("-A" "$current_log_error_file")
[ -f "$current_log_ssh_file" ] && attachments+=("-A" "$current_log_ssh_file")
[ -f "$tar_filename" ] && attachments+=("-A" "$tar_filename")

# E-Mail senden
mail -s "Wöchentliche Serverwartung $server_name $current_date" "$recipient_email" "${attachments[@]}" <<< "$message"
