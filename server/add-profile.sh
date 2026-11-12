#!/bin/bash
# Pacely: add a separate profile for someone else (their own login, plans and password).
# Usage:  /opt/pacely/add-profile.sh name      e.g.  /opt/pacely/add-profile.sh partner
# The domain is worked out from your existing Cloudflare tunnel, or set PACELY_DOMAIN=yourdomain.com first.
DOMAIN=${PACELY_DOMAIN:-$(grep -m1 'hostname:' /etc/cloudflared/config.yml 2>/dev/null | awk '{print $3}' | cut -d. -f2-)}
NAME=$(echo "$1" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')
if [ -z "$NAME" ]; then echo "Usage: /opt/pacely/add-profile.sh name"; exit 1; fi
DATA=/opt/pacely/profiles/$NAME
HOST=plan-$NAME.$DOMAIN
mkdir -p "$DATA"
if [ -f "$DATA/port" ]; then PORT=$(cat "$DATA/port"); else
  USED=$(cat /opt/pacely/profiles/*/port 2>/dev/null)
  for p in $(seq 8743 8799); do
    echo "$USED" | grep -qx "$p" && continue
    ss -ltn | grep -q ":$p " && continue
    PORT=$p; break
  done
  echo "$PORT" > "$DATA/port"
fi
PACELY_DATA=$DATA /opt/pacely/venv/bin/python /opt/pacely/app.py --init | tee /tmp/pacely-profile.txt
grep -q "password:" /tmp/pacely-profile.txt && { grep "password:" /tmp/pacely-profile.txt > ~/pacely-password-$NAME.txt; chmod 600 ~/pacely-password-$NAME.txt; }
rm -f /tmp/pacely-profile.txt
MODEL=$(grep -o 'PACELY_AI_MODEL=.*' /etc/systemd/system/pacely.service | cut -d= -f2)
sudo tee /etc/systemd/system/pacely-$NAME.service >/dev/null <<UNIT
[Unit]
Description=Pacely profile $NAME
After=network-online.target
[Service]
User=$(whoami)
WorkingDirectory=/opt/pacely
Environment=PACELY_DATA=$DATA
Environment=PACELY_PORT=$PORT
Environment=PACELY_TZ=$(grep -o 'PACELY_TZ=.*' /etc/systemd/system/pacely.service | cut -d= -f2)
Environment=PACELY_AI_MODEL=${MODEL:-llama3.2:3b}
Environment=PACELY_CONTACT=mailto:admin@${DOMAIN:-example.com}
ExecStart=/opt/pacely/venv/bin/python /opt/pacely/app.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload && sudo systemctl enable --now pacely-$NAME >/dev/null 2>&1 && sudo systemctl restart pacely-$NAME
if [ -n "$DOMAIN" ] && [ -f /etc/cloudflared/config.yml ] && ! grep -q "$HOST" /etc/cloudflared/config.yml; then
  sudo sed -i "s|^  - service: http_status:404|  - hostname: $HOST\n    service: http://localhost:$PORT\n  - service: http_status:404|" /etc/cloudflared/config.yml
  TUNNEL=$(grep -m1 '^tunnel:' /etc/cloudflared/config.yml | awk '{print $2}')
  cloudflared tunnel route dns "$TUNNEL" "$HOST" >/dev/null 2>&1
  sudo systemctl restart cloudflared
fi
IP=$(hostname -I | awk '{print $1}')
echo; echo "=================================================="
echo " Profile '$NAME' is ready"
echo " Address:  https://$HOST   (at home: http://$IP:$PORT)"
echo " Password: cat ~/pacely-password-$NAME.txt"
echo "=================================================="
