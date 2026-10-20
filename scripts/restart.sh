#!/bin/sh
# Omada watchdog restart script, run on the Proxmox host through a forced-command SSH key.
# Usage: restart.sh "<reason>"   ("test" only writes a log line, no restart)
CT=${OMADA_CT:-400}            # container id of the Omada controller
LOG=/var/log/omada-watchdog.log
# the n8n SSH node sends "cd <dir>" + newline + command: keep only the last line
REASON=$(printf '%s' "${SSH_ORIGINAL_COMMAND:-$*}" | tail -n 1 | sed -E "s/^cd [^;&]*(&&|;) *//" | tr -cd '[:alnum:] :/._=-' | cut -c1-200)
# one restart at a time
exec 9>/run/omada-watchdog.lock
flock -n 9 || { echo BUSY; exit 0; }
ts() { date '+%F %T'; }
snap() {
  pct exec $CT -- sh -c 'echo "svc=$(systemctl is-active tpeap) mem_used_mb=$(free -m | awk "/Mem:/{print \$3}") java_rss_mb=$(ps -o rss= -C jsvc | sort -n | tail -1 | awk "{print int(\$1/1024)}") mongod_rss_mb=$(ps -o rss= -C mongod | awk "{print int(\$1/1024)}") uptime=$(cut -d. -f1 /proc/uptime)s"' 2>&1 | tr '\n' ' '
}
if [ "$REASON" = test ]; then echo "$(ts) TEST (no restart): $(snap)" >> $LOG; echo TEST; exit 0; fi
oom=$(journalctl -k --since "-2h" --no-pager 2>/dev/null | grep -c "oom_memcg=/lxc/$CT")
echo "$(ts) RESTART reason=\"$REASON\" before: $(snap) oom_kills_2h=$oom" >> $LOG
pct exec $CT -- systemctl restart tpeap
i=0; while [ $i -lt 60 ]; do pct exec $CT -- sh -c 'ss -ltn | grep -q ":8043 "' && break; sleep 5; i=$((i+1)); done
if pct exec $CT -- sh -c 'ss -ltn | grep -q ":8043 "'; then r=OK; else r=FAILED; fi
echo "$(ts) RESULT $r after $((i*5))s: $(snap)" >> $LOG
echo "$r"
