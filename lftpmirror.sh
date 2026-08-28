#!/bin/bash

lftp -u "bu320819",'2#N88V8H#UXJ1#8n88QMV33' "backup.1blu.de" << EOF

mirror -ceR /media/backup /jugendwerk_landau
mirror -ceR /media/backup_cnfg /jugendwerk_landau_cnfg

bye
EOF
