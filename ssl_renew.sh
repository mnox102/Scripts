#!/bin/bash
timestamp=$(date +%F_%T)

echo " "
echo "--------------------------------------------------"
echo "SSL Renew Skript startet um $timestamp"
echo "--------------------------------------------------"
echo " "

echo "Starte Certbot Container und prüfe auf neues Zertifikat"
# Run the certbot container to renew the certs
docker compose -f /opt/relution/docker-compose.yml run --rm  certbot certonly --webroot --webroot-path /var/www/certbot/ -d relution.jugendwerk-landau.de --keep-until-expiring

echo "Starte NGINX Container neu um ggf. neues Zertifikat einzubinden"
# Reload NGINX Cert
sleep 600
docker compose -f /opt/relution/docker-compose.yml restart nginx
