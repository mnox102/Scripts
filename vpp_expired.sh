#!/bin/bash

# Datenbank-Parameter
destination=/opt/wartung/log_`date +"%Y-%m-%d"`

# SQL-Abfrage
SQL_QUERY_EXPIRE="SELECT DATE_FORMAT(FROM_UNIXTIME(FLOOR(expiration_date/1000)), '%d.%m.%Y') AS Ablaufdatum, mdm_info_name AS Eindeutiger_Orga_Name FROM mam_vpp_tkn WHERE DATE_FORMAT(FROM_UNIXTIME(FLOOR(expiration_date/1000)), '%Y-%m-%d') < CURDATE();"
SQL_QUERY_STATE="SELECT mdm_info_name AS Eindeutiger_Orga_Name, subscription_state AS Synch_Status FROM mam_vpp_tkn WHERE subscription_state!='SUCCESS';"

# Ausführung der SQL-Abfrage und Ausgabe der Ergebnisse
echo -e "\n----------------------------------------" >> $destination
echo -e "Ueberpruefen auf abgelaufene Token ..." >> $destination
echo -e "\n----------------------------------------" >> $destination
docker exec docker_mariadb mysql -D relution -e "${SQL_QUERY_EXPIRE}" >> $destination

echo -e "\n----------------------------------------" >> $destination
echo -e "Ueberpruefen auf fehlerhafte Synchronisierung ..." >> $destination
echo -e "\n----------------------------------------" >> $destination
docker exec docker_mariadb mysql -D relution -e "${SQL_QUERY_STATE}" >> $destination
