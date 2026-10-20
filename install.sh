#!/bin/bash
# omada-controller-oom-fix installer. Run on the Proxmox host as root:
#   bash <(curl -fsSL https://raw.githubusercontent.com/dllfpp/omada-controller-oom-fix/main/install.sh)
# Add --dry-run to only print what it would do.
# Non-interactive: OMADA_CT=400 OMADA_IP=192.168.1.10 OMADA_RESTART=n \
#   N8N_URL=http://192.168.1.20:5678 N8N_API_KEY=... bash install.sh   (N8N_URL empty = set up n8n by hand)
set -euo pipefail

REPO=https://raw.githubusercontent.com/dllfpp/omada-controller-oom-fix/main
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
run() { if [ $DRY = 1 ]; then echo "  [dry-run] $*"; else eval "$@"; fi; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { echo "Error: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root on the Proxmox host"
command -v pct >/dev/null || die "pct not found: this must run on a Proxmox VE host"

say "Omada controller OOM fix"
[ $DRY = 1 ] && echo "Dry run: nothing will be changed."

CT=${OMADA_CT:-}; [ -n "$CT" ] || read -rp "Container id of the Omada controller (e.g. 400): " CT </dev/tty
[[ "$CT" =~ ^[0-9]+$ ]] || die "invalid container id"
pct status "$CT" >/dev/null 2>&1 || die "container $CT not found"
pct status "$CT" | grep -q running || die "container $CT is not running"
pct exec "$CT" -- test -f /opt/tplink/EAPController/bin/control.sh || die "Omada not found in container $CT"

IP=${OMADA_IP:-}; [ -n "$IP" ] || read -rp "Controller IP or hostname (e.g. 192.168.1.10): " IP </dev/tty
[[ "$IP" =~ ^[A-Za-z0-9.:-]+$ ]] || die "invalid address"
if curl -sk -m10 "https://$IP:8043/api/info" | grep -q omadacId; then echo "Controller answers on https://$IP:8043"
else echo "Warning: https://$IP:8043/api/info does not answer now (controller down or wrong address)."; fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
for f in scripts/omada-limits.sh systemd/limits.conf scripts/restart.sh n8n/omada-watchdog.json; do
  curl -fsSL "$REPO/$f" -o "$TMP/$(basename "$f")" || die "download of $f failed"
done

say "1/3 Off-heap memory limits (inside container $CT)"
run "pct exec $CT -- cp -n /opt/tplink/EAPController/bin/control.sh /root/control.sh.pre-limits"
run "pct push $CT $TMP/omada-limits.sh /root/omada-limits.sh --perms 755"
run "pct exec $CT -- mkdir -p /etc/systemd/system/tpeap.service.d"
run "pct push $CT $TMP/limits.conf /etc/systemd/system/tpeap.service.d/limits.conf"
run "pct exec $CT -- systemctl daemon-reload"
run "pct exec $CT -- /root/omada-limits.sh"
[ $DRY = 0 ] && pct exec "$CT" -- grep -nE '^export MALLOC|^JAVA_OPTS' /opt/tplink/EAPController/bin/control.sh
echo "The limits are active from the next start of the controller."
R=${OMADA_RESTART:-}; [ -n "$R" ] || read -rp "Restart the controller now? It is unreachable for 2-5 minutes. [y/N] " R </dev/tty
if [[ "$R" =~ ^[yY] ]]; then
  run "pct exec $CT -- systemctl restart tpeap"
  if [ $DRY = 0 ]; then
    echo -n "Waiting for the API"
    for _ in $(seq 1 60); do curl -sk -m10 "https://$IP:8043/api/info" | grep -q omadacId && break; echo -n .; sleep 10; done; echo
  fi
fi

say "2/3 Watchdog restart script and restricted SSH key (on this host)"
KEY=/root/.ssh/n8n_omada_watchdog
run "mkdir -p /root/omada-watchdog"
run "sed 's/^CT=\${OMADA_CT:-400}/CT=\${OMADA_CT:-$CT}/' $TMP/restart.sh > /root/omada-watchdog/restart.sh"
run "chmod 700 /root/omada-watchdog/restart.sh"
[ -f $KEY ] || run "ssh-keygen -q -t ed25519 -N '' -C n8n-omada-watchdog -f $KEY"
if [ -f $KEY.pub ] && grep -qF "$(cut -d" " -f2 $KEY.pub)" /root/.ssh/authorized_keys 2>/dev/null; then echo "Key already authorized."
else
  run "cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.bak-omada-watchdog"
  run "echo \"command=\\\"/root/omada-watchdog/restart.sh\\\",restrict \$(cat $KEY.pub)\" >> /root/.ssh/authorized_keys"
fi
if [ $DRY = 0 ]; then
  echo -n "Key test (no restart): "; ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@127.0.0.1 test
fi

say "3/3 n8n workflow"
OUT=/root/omada-watchdog/omada-watchdog.json
run "sed 's/OMADA_CONTROLLER_IP/$IP/' $TMP/omada-watchdog.json > $OUT"
HOST=$(hostname -I | awk '{print $1}')
N8N=${N8N_URL:-}; [ -n "$N8N" ] || read -rp "n8n URL (e.g. http://192.168.1.20:5678, empty = set up n8n by hand): " N8N </dev/tty
N8N=${N8N%/}
if [ -n "$N8N" ]; then
  KEYAPI=${N8N_API_KEY:-}; [ -n "$KEYAPI" ] || { read -rsp "n8n API key (Settings > n8n API): " KEYAPI </dev/tty; echo; }
  [ -n "$KEYAPI" ] || die "n8n API key is empty"
  code=$(curl -s -o /dev/null -w '%{http_code}' -m10 -H "X-N8N-API-KEY: $KEYAPI" "$N8N/api/v1/workflows?limit=1")
  [ "$code" = 200 ] || die "n8n API not reachable or key refused (HTTP $code) at $N8N"
  echo "n8n API OK at $N8N"
  if [ $DRY = 1 ]; then
    echo "  [dry-run] create n8n credential 'Omada watchdog key' (SSH root@$HOST, key $KEY)"
    echo "  [dry-run] create and activate workflow 'Omada watchdog' from $OUT"
  else
    # the private key goes from file to the n8n API through a pipe, never on the command line
    cred=$(KEY=$KEY HOST=$HOST python3 -c 'import json,os;print(json.dumps({"name":"Omada watchdog key","type":"sshPrivateKey","data":{"host":os.environ["HOST"],"port":22,"username":"root","privateKey":open(os.environ["KEY"]).read(),"passphrase":""}}))' \
      | curl -s -m20 -H "X-N8N-API-KEY: $KEYAPI" -H 'Content-Type: application/json' -X POST "$N8N/api/v1/credentials" -d @- \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')
    [ -n "$cred" ] || die "n8n credential not created"
    wf=$(CRED=$cred python3 -c 'import json,os,sys;w=json.load(open(sys.argv[1]));[n["credentials"]["sshPrivateKey"].update(id=os.environ["CRED"],name="Omada watchdog key") for n in w["nodes"] if "credentials" in n];print(json.dumps(w))' "$OUT" \
      | curl -s -m20 -H "X-N8N-API-KEY: $KEYAPI" -H 'Content-Type: application/json' -X POST "$N8N/api/v1/workflows" -d @- \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')
    [ -n "$wf" ] || die "n8n workflow not created (credential $cred was created)"
    act=$(curl -s -m20 -H "X-N8N-API-KEY: $KEYAPI" -X POST "$N8N/api/v1/workflows/$wf/activate" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("active"))')
    echo "n8n: credential $cred, workflow $wf, active=$act"
  fi
  cat <<EOF

Done. n8n checks https://$IP:8043 every hour at minute 17 and restarts the controller if it does not answer.
Log of every restart: /var/log/omada-watchdog.log
Test the key any time: ssh -i $KEY root@$HOST test
EOF
else
  cat <<EOF

Done. In n8n:
  1. Credentials > New > SSH Private Key
       host: $HOST   user: root   private key: the content of $KEY
  2. Workflows > Import from file > $OUT
  3. Open "Restart Omada", select that credential, save and activate.

Log of every restart: /var/log/omada-watchdog.log
Test the key any time: ssh -i $KEY root@$HOST test
EOF
fi
