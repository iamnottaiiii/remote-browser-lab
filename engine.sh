#!/usr/bin/env bash
# Live browser engine. Runs on a GitHub Actions runner.
# Chrome on a virtual screen, streamed through a Cloudflare quick tunnel.
# The public link is written to live.json and committed back to this repo.
# The Chrome profile is saved (AES-256 encrypted) into the repo and
# restored at the next start, when PROFILE_KEY is set. A Save page
# inside the session lets the person save manually at any moment.

VNC_PASS="${VNC_PASS:-bjvfi-live}"
export BROWSER_REPO_DIR="$(pwd)"

sudo apt-get update -qq
sudo apt-get install -y -qq xvfb x11vnc novnc websockify openbox tint2 rsync fonts-liberation fonts-noto-core > /dev/null
if ! command -v google-chrome > /dev/null; then
  wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  sudo apt-get install -y -qq ./google-chrome-stable_current_amd64.deb > /dev/null
fi
curl -sL -o /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /tmp/cloudflared

# Home IP routing: when TS_AUTHKEY is set, this session joins the
# tailnet and sends its traffic out through the home exit node, so
# sites see the home IP instead of the datacenter's.
TS_STATUS='no auth key'
TS_PEERS=''
if [ -n "$TS_AUTHKEY" ]; then
  GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
  DEV=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
  curl -fsSL https://tailscale.com/install.sh | sh > /dev/null 2>&1
  sudo tailscaled > /tmp/tailscaled.log 2>&1 &
  sleep 3
  if sudo tailscale up --authkey "$TS_AUTHKEY" --hostname bjvfi-browser --accept-dns=false > /tmp/tailscale-up.log 2>&1; then
    TS_STATUS='joined, looking for exit node'
  else
    TS_STATUS='join failed'
    cat /tmp/tailscale-up.log
  fi
  EXIT_IP=''
  for i in $(seq 1 12); do
    EXIT_IP=$(tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for p in (d.get("Peer") or {}).values():
    if p.get("ExitNodeOption"):
        ips = p.get("TailscaleIPs") or []
        if ips:
            print(ips[0])
            break
' 2>/dev/null)
    if [ -n "$EXIT_IP" ]; then break; fi
    sleep 5
  done
  if [ -n "$EXIT_IP" ]; then
    sudo tailscale set --exit-node "$EXIT_IP" || true
    if [ -n "$GW" ]; then
      for NET in 198.41.192.0/24 198.41.200.0/24; do
        sudo ip route add $NET via $GW dev $DEV table 52 > /dev/null 2>&1 || true
      done
    fi
    TS_STATUS="exit node $EXIT_IP"
    echo "Home IP routing on, exit node $EXIT_IP"
  else
    if [ "$TS_STATUS" = 'joined, looking for exit node' ]; then
      TS_STATUS='no exit node on tailnet'
    fi
    echo 'No exit node found on the tailnet, browsing keeps the datacenter IP'
  fi
  TS_PEERS=$(tailscale status --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
out = []
for p in (d.get('Peer') or {}).values():
    name = (p.get('HostName') or '?').strip()
    out.append(name + (' (exit offered)' if p.get('ExitNodeOption') else ''))
print(', '.join(out) if out else 'none')
" 2>/dev/null)
fi

# The save script, shared by the auto-save and the manual Save page.
cat > $HOME/do-save.sh << 'SAVE_EOF'
#!/usr/bin/env bash
exec 9>/tmp/save.lock
if ! flock -n 9; then
  echo 'A save is already running'
  exit 3
fi
if [ -z "$PROFILE_KEY" ] && [ -f "$HOME/.browser-save-key" ]; then
  PROFILE_KEY=$(cat "$HOME/.browser-save-key")
  export PROFILE_KEY
fi
if [ -z "$PROFILE_KEY" ]; then
  echo 'Saving is not switched on'
  exit 2
fi
cd "$BROWSER_REPO_DIR" || exit 1
rm -rf /tmp/prof-stage && mkdir -p /tmp/prof-stage
rsync -a \
  --exclude='*/Cache/*' --exclude='*/Code Cache/*' --exclude='*/GPUCache/*' \
  --exclude='*/Service Worker/CacheStorage/*' --exclude='*/blob_storage/*' \
  --exclude='SingletonLock' --exclude='SingletonCookie' --exclude='SingletonSocket' \
  $HOME/chrome-profile/ /tmp/prof-stage/ 2>/dev/null
if tar -czf - -C /tmp/prof-stage . 2>/dev/null | openssl enc -aes-256-cbc -salt -pbkdf2 -pass env:PROFILE_KEY -out profile.tar.gz.enc 2>/dev/null; then
  git add profile.tar.gz.enc
  git commit -m 'profile save' > /dev/null 2>&1 || true
  git push > /dev/null 2>&1 || true
  echo 'Saved'
  exit 0
fi
echo 'Save failed'
exit 1
SAVE_EOF
chmod +x $HOME/do-save.sh

# The key lives in a private file inside the session only, so the
# Save page can run saves without the secret in its own hands.
if [ -n "$PROFILE_KEY" ]; then
  printf '%s' "$PROFILE_KEY" > $HOME/.browser-save-key
  chmod 600 $HOME/.browser-save-key
fi

# The Save page: a tiny local web page with one big button.
cat > $HOME/save-server.py << 'PYEOF'
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

PAGE = """<!DOCTYPE html>
<html><head><meta charset='utf-8'><title>Save this browser</title>
<style>body{font-family:monospace;padding:40px 24px;font-size:22px;color:#111}
button{font-size:26px;padding:20px 34px;background:#111;color:#fff;border:0;width:100%}
</style></head><body>
<p>This page saves the whole browser: tabs, bookmarks, history, logins.</p>
<form method='POST' action='/save'><button type='submit'>SAVE NOW</button></form>
<p>{note}</p>
</body></html>"""

class Handler(BaseHTTPRequestHandler):
    def _send(self, note):
        body = PAGE.replace('{note}', note).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send('Auto-save also runs every 20 minutes while the browser is on.')

    def do_POST(self):
        if self.path != '/save':
            self._send('')
            return
        try:
            result = subprocess.run(['bash', os.path.expanduser('~/do-save.sh')],
                                    capture_output=True, text=True, timeout=180)
            out = (result.stdout or '') + (result.stderr or '')
        except Exception:
            out = 'failed'
        if 'Saved' in out:
            note = 'Saved. Everything in this browser is packed away safely.'
        elif 'already running' in out:
            note = 'A save is already running. Give it a few seconds.'
        elif 'not switched on' in out:
            note = 'Saving is not switched on yet. It turns on with the PROFILE_KEY secret.'
        else:
            note = 'The save did not finish. The auto-save will try again soon.'
        self._send(note)

    def log_message(self, *args):
        pass

HTTPServer(('127.0.0.1', 8080), Handler).serve_forever()
PYEOF

sudo timedatectl set-timezone America/New_York > /dev/null 2>&1 || true
export TZ=America/New_York
Xvfb :99 -screen 0 1280x800x24 > /tmp/xvfb.log 2>&1 &
sleep 2
DISPLAY=:99 openbox > /tmp/openbox.log 2>&1 &
DISPLAY=:99 tint2 > /tmp/tint2.log 2>&1 &
mkdir -p ~/.vnc
x11vnc -storepasswd "$VNC_PASS" ~/.vnc/passwd > /dev/null 2>&1
x11vnc -display :99 -rfbport 5900 -rfbauth ~/.vnc/passwd -forever -shared -bg -o /tmp/x11vnc.log
websockify --web=/usr/share/novnc 6080 localhost:5900 > /tmp/websockify.log 2>&1 &
python3 $HOME/save-server.py > /tmp/save-server.log 2>&1 &

# Restore the saved browser profile, if one exists and the key is set.
# The save file is AES-256 encrypted; without PROFILE_KEY it is opaque.
if [ -n "$PROFILE_KEY" ] && [ -f profile.tar.gz.enc ]; then
  mkdir -p $HOME/chrome-profile
  if openssl enc -d -aes-256-cbc -pbkdf2 -pass env:PROFILE_KEY -in profile.tar.gz.enc 2>/dev/null | tar -xzf - -C $HOME/chrome-profile 2>/dev/null; then
    rm -f $HOME/chrome-profile/SingletonLock $HOME/chrome-profile/SingletonCookie $HOME/chrome-profile/SingletonSocket
    echo 'Saved profile restored'
  else
    echo 'Saved profile could not be opened, starting fresh'
  fi
fi

DISPLAY=:99 google-chrome --no-sandbox --disable-dev-shm-usage --no-first-run --start-maximized --lang=en-US --force-webrtc-ip-handling-policy=disable_non_proxied_udp --disable-blink-features=AutomationControlled --user-data-dir=$HOME/chrome-profile https://duckduckgo.com http://127.0.0.1:8080/ > /tmp/chrome.log 2>&1 &

if [ -n "$TUNNEL_TOKEN" ]; then
  # Named tunnel: the browser lives at browser.bjvfi.com.
  /tmp/cloudflared tunnel --no-autoupdate run --token "$TUNNEL_TOKEN" > /tmp/tunnel.log 2>&1 &
  URL='https://desk.bjvfi.com'
  sleep 5
  echo "Named tunnel starting: $URL"
else
  # Quick tunnel fallback, a fresh random address each run.
  /tmp/cloudflared tunnel --url http://localhost:6080 --no-autoupdate --protocol http2 > /tmp/tunnel.log 2>&1 &
  URL=''
  for i in $(seq 1 30); do
    URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/tunnel.log | head -1)
    if [ -n "$URL" ]; then break; fi
    sleep 2
  done
  if [ -z "$URL" ]; then
    echo 'Tunnel did not come up'
    cat /tmp/tunnel.log
    exit 1
  fi
  echo "Tunnel is live: $URL"
fi

git config user.name 'browser-bot'
git config user.email 'browser-bot@users.noreply.github.com'

publish() {
  TUNNEL_URL="$URL" VNC_PASS="$VNC_PASS" TS_STATUS="$TS_STATUS" TS_PEERS="$TS_PEERS" python3 -c "
import json, os, datetime
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
url = os.environ['TUNNEL_URL'] + '/vnc.html?autoconnect=true&password=' + os.environ['VNC_PASS'] + '&resize=scale'
try:
    d = json.load(open('live.json'))
except Exception:
    d = {}
d['url'] = url
d.setdefault('started', now)
d['heartbeat'] = now
d['state'] = 'live'
d['ts'] = os.environ.get('TS_STATUS', '')
d['peers'] = os.environ.get('TS_PEERS', '')
try:
    import urllib.request
    d['ip'] = urllib.request.urlopen('https://api.ipify.org', timeout=5).read().decode().strip()
except Exception:
    pass
json.dump(d, open('live.json', 'w'), indent=2)
"
  git add live.json
  git commit -m 'browser live' > /dev/null || true
  git push > /dev/null || true
}

save_profile() {
  bash $HOME/do-save.sh || true
}

publish

# Always on: at 300 minutes this run calls the next run into being,
# so a fresh session takes over before this one ends. A dispatch
# started from inside a run is allowed to start a new run, so the
# chain needs no human.
(
  sleep 18000
  AUTH=$(git config --get http.https://github.com/.extraheader 2>/dev/null | awk '{print $NF}')
  TOKEN=$(printf '%s' "$AUTH" | base64 -d 2>/dev/null | sed 's/^x-access-token://')
  if [ -n "$TOKEN" ]; then
    curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" https://api.github.com/repos/iamnottaiiii/remote-browser/actions/workflows/browser.yml/dispatches -d '{"ref":"main"}' > /dev/null 2>&1
  fi
) > /dev/null 2>&1 &

# Keep the session alive, refreshing the heartbeat so the door page
# knows the browser is awake. The job itself is capped by the
# workflow timeout (355 minutes). The profile is saved every
# fourth cycle, about every 20 minutes, and once more at the end.
for i in $(seq 1 64); do
  sleep 300
  publish
  if [ $((i % 4)) -eq 0 ]; then
    save_profile
  fi
done
save_profile
