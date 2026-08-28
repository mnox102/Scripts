#!/bin/bash
timestamp=$(date +%F_%T)

echo " "
echo "--------------------------------------------------"
echo "Relution Update Skript startet um $timestamp"
echo "--------------------------------------------------"
echo " "

# Restart and Pull new Image for Relution Container

echo "Lade neues Image"
docker compose -f /opt/relution/docker-compose.yml pull

echo "Stoppe Relution Container"
docker compose -f /opt/relution/docker-compose.yml down

sleep 10

echo "Starte Relution Container"
docker compose -f /opt/relution/docker-compose.yml up -d

# Restart NGINX to prevent Bug
sleep 600
docker compose -f /opt/relution/docker-compose.yml down nginx
docker compose -f /opt/relution/docker-compose.yml up nginx -d
