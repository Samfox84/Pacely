#!/bin/bash
# Puts Pacely on the internet at https://<hostname> using a free Cloudflare Tunnel.
# You need a domain whose DNS is managed by Cloudflare.   Usage:   bash setup-tunnel.sh plan.yourdomain.com
# Already have a tunnel on this computer (for other websites)? Pacely is added to it; your other sites are kept.
set -u
HOST=${1:-}
PORT=${PACELY_PORT:-8742}
CONF=/etc/cloudflared/config.yml
if [ -z "$HOST" ]; then echo "Usage: bash setup-tunnel.sh plan.yourdomain.com"; exit 1; fi
HOST=${HOST#https://}; HOST=${HOST#http://}; HOST=${HOST%%/*}

if ! command -v cloudflared >/dev/null; then
  echo "Installing cloudflared (Cloudflare's tunnel program)…"
  sudo mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
  sudo apt-get update -qq && sudo apt-get install -y -qq cloudflared
fi
if [ ! -f ~/.cloudflared/cert.pem ]; then
  echo; echo ">>> Open the link below, log in to Cloudflare and click your domain, then come back here <<<"; echo
  cloudflared tunnel login || { echo "Cloudflare login didn't finish. Run this again."; exit 1; }
fi

# Use the tunnel this computer already has, if there is one
TID=""
if sudo test -f "$CONF"; then
  TID=$(sudo awk '/^tunnel:/{print $2; exit}' "$CONF")
fi
if [ -n "$TID" ]; then
  echo "Adding Pacely to your existing tunnel ($TID)…"
  sudo cp "$CONF" "$CONF.before-pacely"
  sudo python3 - "$CONF" "$HOST" "$PORT" <<'PY'
import sys, re
path, host, port = sys.argv[1:]
lines = open(path).read().splitlines()
# drop an older Pacely rule for the same address
out, skip = [], False
for l in lines:
    if re.match(r'\s*-\s*hostname:\s*' + re.escape(host) + r'\s*$', l):
        skip = True; continue
    if skip and re.match(r'\s+service:', l) and not l.lstrip().startswith('-'):
        skip = False; continue
    skip = False
    out.append(l)
rule = [f'  - hostname: {host}', f'    service: http://localhost:{port}']
if not any(l.strip() == 'ingress:' for l in out):
    out += ['ingress:'] + rule + ['  - service: http_status:404']
else:
    i = next((n for n, l in enumerate(out) if re.match(r'\s*-\s*service:', l)), None)  # the catch-all rule
    if i is None:
        out += rule + ['  - service: http_status:404']
    else:
        out[i:i] = rule
open(path, 'w').write('\n'.join(out) + '\n')
PY
  cloudflared tunnel route dns --overwrite-dns "$TID" "$HOST"
else
  cloudflared tunnel list 2>/dev/null | grep -qw pacely || cloudflared tunnel create pacely
  TID=$(cloudflared tunnel list -o json | python3 -c "import json,sys;print(next((t['id'] for t in json.load(sys.stdin) if t['name']=='pacely'),''))")
  [ -n "$TID" ] || { echo "Couldn't create the tunnel. Take a screenshot of this window and ask for help."; exit 1; }
  cloudflared tunnel route dns --overwrite-dns pacely "$HOST"
  sudo mkdir -p /etc/cloudflared
  sudo cp ~/.cloudflared/"$TID".json /etc/cloudflared/"$TID".json
  sudo tee "$CONF" >/dev/null <<CFG
tunnel: $TID
credentials-file: /etc/cloudflared/$TID.json
ingress:
  - hostname: $HOST
    service: http://localhost:$PORT
  - service: http_status:404
CFG
fi

if ! systemctl list-unit-files | grep -q '^cloudflared.service'; then
  sudo tee /etc/systemd/system/cloudflared.service >/dev/null <<UNIT
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$(command -v cloudflared) --no-autoupdate --config $CONF tunnel run
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
fi
sudo systemctl daemon-reload && sudo systemctl enable cloudflared >/dev/null 2>&1 && sudo systemctl restart cloudflared
echo "Waiting for it to connect…"; sleep 15
echo
if curl -fs -o /dev/null "https://$HOST/"; then
  echo " ✅ Done! Open https://$HOST"
else
  echo " Set up. Give it two minutes, then open https://$HOST"
  echo " Still not working? Run:  sudo systemctl status cloudflared   and see docs/setup-server.md"
fi
