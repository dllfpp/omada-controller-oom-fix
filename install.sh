#!/bin/bash
# omada-controller-oom-fix installer. Run on the Proxmox host as root:
#   bash <(curl -fsSL https://raw.githubusercontent.com/dllfpp/omada-controller-oom-fix/main/install.sh)
# Add --dry-run to only print what it would do.
# Non-interactive: OMADA_CT=400 OMADA_IP=192.168.1.10 OMADA_RESTART=n bash install.sh
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
if grep -q n8n-omada-watchdog /root/.ssh/authorized_keys 2>/dev/null; then echo "Key already authorized."
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
cat <<EOF

Done. In n8n:
  1. Credentials > New > SSH Private Key
       host: $HOST   user: root   private key: the content of $KEY
  2. Workflows > Import from file > $OUT
  3. Open "Restart Omada", select that credential, save and activate.

Log of every restart: /var/log/omada-watchdog.log
Test the key any time: ssh -i $KEY root@$HOST test
EOF
