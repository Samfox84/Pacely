#!/bin/bash
# Pacely server installer for Ubuntu / Debian (including Raspberry Pi OS).
# Run from the folder you downloaded:   bash install.sh
# Safe to run again to update - your plans and password are kept.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT=${PACELY_PORT:-8742}
ME=$(whoami)
TZNAME=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)
echo "Installing Pacely…"
if ss -ltn | grep -q ":$PORT " && ! systemctl is-active --quiet pacely; then
  echo "Port $PORT is already in use by something else. Run again with a different port, e.g.  PACELY_PORT=8750 bash install.sh"; exit 1
fi
sudo apt-get update -qq && sudo apt-get install -y -qq python3-venv python3-pip curl >/dev/null
sudo mkdir -p /opt/pacely && sudo chown -R "$ME":"$ME" /opt/pacely
cp -r "$HERE/server/." /opt/pacely/
chmod +x /opt/pacely/add-profile.sh
[ -d /opt/pacely/venv ] || python3 -m venv /opt/pacely/venv
/opt/pacely/venv/bin/pip install -q --upgrade pip flask waitress pywebpush cryptography icalendar recurring_ical_events
/opt/pacely/venv/bin/python /opt/pacely/make_icons.py /opt/pacely/static
PACELY_DATA=/opt/pacely/data PACELY_TZ=$TZNAME /opt/pacely/venv/bin/python /opt/pacely/app.py --init | tee /tmp/pacely-init.txt
grep -q "password:" /tmp/pacely-init.txt && { grep "password:" /tmp/pacely-init.txt > ~/pacely-password.txt; chmod 600 ~/pacely-password.txt; }
rm -f /tmp/pacely-init.txt

# Optional private AI helper (Ollama). Skip with PACELY_AI=no. You can also use Google Gemini instead, in the app.
MODEL=${PACELY_AI_MODEL:-}
if [ "${PACELY_AI:-ask}" = "ask" ] && [ -t 0 ]; then
  echo; read -r -p "Install the private AI helper on this server? It downloads about 3 GB. [Y/n] " ans
  case "$ans" in [nN]*) PACELY_AI=no ;; *) PACELY_AI=yes ;; esac
fi
if [ "${PACELY_AI:-ask}" != "no" ]; then
  command -v ollama >/dev/null || curl -fsSL https://ollama.com/install.sh | sh
  sudo systemctl enable --now ollama >/dev/null 2>&1
  for i in $(seq 1 10); do curl -fs -o /dev/null http://127.0.0.1:11434/api/tags && break; sleep 2; done
  if [ -z "$MODEL" ]; then MEM=$(free -g | awk '/Mem:/{print $2}'); MODEL=llama3.2:3b; [ "${MEM:-0}" -lt 7 ] && MODEL=llama3.2:1b; fi
  ollama pull "$MODEL"
fi

sudo tee /etc/systemd/system/pacely.service >/dev/null <<UNIT
[Unit]
Description=Pacely day planner
After=network-online.target
[Service]
User=$ME
WorkingDirectory=/opt/pacely
Environment=PACELY_DATA=/opt/pacely/data
Environment=PACELY_PORT=$PORT
Environment=PACELY_TZ=$TZNAME
Environment=PACELY_AI_MODEL=${MODEL:-llama3.2:3b}
Environment=PACELY_CONTACT=${PACELY_CONTACT:-mailto:admin@example.com}
EnvironmentFile=-/etc/default/pacely
ExecStart=/opt/pacely/venv/bin/python /opt/pacely/app.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload && sudo systemctl enable --now pacely >/dev/null 2>&1 && sudo systemctl restart pacely
sleep 3
IP=$(hostname -I | awk '{print $1}')
echo; echo "=================================================="
if curl -fs -o /dev/null "http://localhost:$PORT/"; then echo " Pacely is running"; else echo " Pacely did not start - run: sudo journalctl -u pacely -n 30"; fi
echo " On your home network:  http://$IP:$PORT"
echo " Password saved in:     ~/pacely-password.txt   (show it: cat ~/pacely-password.txt)"
echo " To use it away from home with https (needed for phone notifications):"
echo "     bash setup-tunnel.sh plan.yourdomain.com"
echo "=================================================="
