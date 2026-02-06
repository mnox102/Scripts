#!/bin/bash

OUTPUT="/var/log/all_users_history_by_day.txt"
: > "$OUTPUT"

echo "Sammle und sortiere History aller User tageweise..." | tee -a "$OUTPUT"

# Alle User aus /etc/passwd lesen
cut -d: -f1,6 /etc/passwd | while IFS=: read -r USERNAME USER_HOME; do
    HISTORY_FILE="$USER_HOME/.bash_history"
    [ -f "$HISTORY_FILE" ] || continue

    echo -e "\n==============================" >> "$OUTPUT"
    echo "USER: $USERNAME" >> "$OUTPUT"
    echo "HOME: $USER_HOME" >> "$OUTPUT"
    echo "==============================\n" >> "$OUTPUT"

    # History parsen und sortieren
    awk '
        /^#/ {
            # Timestamp found -> convert to date
            timestamp = substr($0, 3)
            cmd_date = strftime("%Y-%m-%d", timestamp)
            next
        }
        {
            # regular command, print with its date
            if (cmd_date != "")
                print cmd_date " | " $0
            else
                print "NO_DATE | " $0
        }
    ' "$HISTORY_FILE" >> "$OUTPUT"

done

echo -e "\nFertig! Gespeichert in: $OUTPUT"
``
