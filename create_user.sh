#!/bin/bash

# Eingaben vom Benutzer abfragen
read -p "Geben Sie den Benutzernamen ein (Format: m_ecke): " username
read -p "Geben Sie den vollständigen Namen des Benutzers ein: " fullname

# Funktion zur Überprüfung des Passworts auf Sonderzeichen
check_password() {
    if [[ "$1" =~ [^a-zA-Z0-9] ]]; then
        echo "Das Passwort darf keine Sonderzeichen enthalten. Bitte versuchen Sie es erneut."
        return 1
    else
        return 0
    fi
}

# Passwort abfragen und auf Sonderzeichen überprüfen
while true; do
    read -s -p "Geben Sie das Passwort ein (ohne Sonderzeichen): " password
    echo
    if check_password "$password"; then
        break
    fi
done

# Hostname ermitteln
hostname=$(hostname)

# Benutzer erstellen
sudo adduser --gecos "$fullname" --disabled-password "$username"
echo "$username:$password" | sudo chpasswd

# Benutzer zu sudo-Gruppe hinzufügen (falls gewünscht)
read -p "Soll der Benutzer Root-Rechte haben? (j/n): " root_rights
if [ "$root_rights" = "j" ]; then
    sudo usermod -a -G sudo "$username"
fi

# Als Benutzer anmelden und SSH-Schlüssel erstellen
sudo su - "$username" <<EOF
mkdir -p ~/.ssh
cd ~/.ssh
ssh-keygen -t rsa -b 4096 -f ssh_key_$hostname -N "$password" -C "$username"
cat ~/.ssh/ssh_key_$hostname.pub >> ~/.ssh/authorized_keys
chmod -R go= ~/.ssh
chown -R $username:$username ~/.ssh
EOF

# Ausgabe des SSH-Schlüssels
echo "Der SSH-Schlüssel wurde erstellt und freigeschaltet. Hier ist der öffentliche Schlüssel:"
cat /home/$username/.ssh/ssh_key_$hostname.pub
