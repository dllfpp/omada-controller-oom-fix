# omada-controller-oom-fix

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/dllfpp/omada-controller-oom-fix/main/install.sh)
```

> [!WARNING]
> **Always read the source code of every script before you run it**, this one included.
> The one-liner runs as root on your Proxmox host: it edits a file inside the controller container,
> adds an SSH key to `/root/.ssh/authorized_keys` and creates objects in n8n. Read
> [`install.sh`](install.sh) and the files it downloads ([`scripts/`](scripts), [`systemd/`](systemd),
> [`n8n/`](n8n)) first, or download it and run it with `--dry-run` to see every action without changing anything:
>
> ```sh
> curl -fsSL https://raw.githubusercontent.com/dllfpp/omada-controller-oom-fix/main/install.sh -o install.sh
> less install.sh
> bash install.sh --dry-run
> ```

Diagnose and fix a self-hosted **TP-Link Omada Network Application** (controller) that gets killed
by the kernel OOM killer, plus an **n8n watchdog** that restarts it and logs every restart.

Tested on Omada Network Application 6.3.0.45, Java 21 (Zulu), MongoDB 7.0, running in a Debian LXC
container (3 GB RAM) on Proxmox VE. The same commands work on a VM or bare metal: drop the
`pct exec <CT> --` prefix.

All outputs below come from a real incident and are anonymized (IPs, names, ids).

## Quick install

Run the one-liner at the top on the Proxmox host, as root, after reading the warning. The wizard asks:

| Question | Example |
|---|---|
| Container id of the Omada controller | `400` |
| Controller IP | `192.168.1.10` |
| Restart the controller now? | `y` / `N` |
| n8n URL (empty = set up n8n by hand) | `http://192.168.1.20:5678` |
| n8n API key (hidden input; n8n Settings > n8n API, see [how to create one](https://docs.n8n.io/api/authentication/)) | |

Then it:

1. installs the off-heap limits and the systemd drop-in that re-applies them on every start (section 2);
2. installs the watchdog restart script and a restricted SSH key, and tests the key without restarting (section 3);
3. through the n8n API, creates the SSH credential and the "Omada watchdog" workflow with your IP, and activates it.
   With an empty n8n URL it writes `/root/omada-watchdog/omada-watchdog.json` and prints the manual steps instead.

Preview without changing anything (it still checks that the controller and the n8n API answer):

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/dllfpp/omada-controller-oom-fix/main/install.sh) --dry-run
```

Non-interactive:

```sh
OMADA_CT=400 OMADA_IP=192.168.1.10 OMADA_RESTART=n \
N8N_URL=http://192.168.1.20:5678 N8N_API_KEY=<key> bash install.sh
```

The sections below explain every command the wizard runs, plus the diagnosis that led to it.

## The symptom

The controller web UI and API stopped answering. The access points kept working (they do not need
the controller to pass traffic), but nothing that talks to the controller worked:

```
ERR fetch failed ECONNREFUSED connect ECONNREFUSED <controller-ip>:8043
```

## 1. Diagnosis

Replace `<CT>` with the container id of the controller and run these on the Proxmox host.

### 1.1 Is the container running?

```sh
pct status <CT>
```

```
status: running
```

The container is up, so the problem is inside it.

### 1.2 Is the controller listening?

```sh
pct exec <CT> -- sh -c "ss -ltnp | grep -E '8043|8088'"
```

No output: nothing listens on 8043 (HTTPS UI/API) or 8088.

### 1.3 Service state

```sh
pct exec <CT> -- systemctl status tpeap
```

```
× tpeap.service - LSB: Omada Network Application
     Active: failed (Result: oom-kill) since Mon 02:20:24; 15h ago
```

`Result: oom-kill`: the kernel killed it and systemd did not restart it.

### 1.4 What the service logged

```sh
pct exec <CT> -- journalctl -u tpeap --since "02:00" --no-pager
```

```
02:18:22 systemd[1]: tpeap.service: A process of this unit has been killed by the OOM killer.
02:19:53 tpeap[3800]: Stop failed, possibly due to high system resource utilization. going to kill it.
02:20:24 systemd[1]: tpeap.service: Failed with result 'oom-kill'.
```

### 1.5 Controller log around the crash

```sh
pct exec <CT> -- sh -c "grep -iE 'shutdown|stop|error|OutOfMemory' /opt/tplink/EAPController/logs/server.log | tail -20"
```

```
WARN  c.t.s.o.s.g.b(): Failed to stop mongod, pid is null
INFO  c.t.s.o.s.h.g(): Stop startup message daemon.
INFO  [SpringApplicationShutdownHook] going to shutdown device connection monitor thread pools.
```

No `OutOfMemoryError`. That means the Java **heap** never filled, so the memory went somewhere else.

### 1.6 Kernel OOM record: who used the memory

Run this on the **Proxmox host** (the kernel log is not visible inside an LXC):

```sh
journalctl -k --since "02:00" --until "02:25" --no-pager | grep -iE "oom|Killed process"
```

```
kernel: Memory cgroup out of memory: Killed process 5089 (jsvc) total-vm:6106796kB, anon-rss:3004160kB ...
kernel: oom-kill:constraint=CONSTRAINT_MEMCG,...,oom_memcg=/lxc/<CT>,task_memcg=/lxc/<CT>/ns/system.slice/tpeap.service,task=jsvc
```

The Java process (`jsvc`) used **3.0 GB** resident, the whole container limit.

### 1.7 Java heap limit

```sh
pct exec <CT> -- grep -n Xmx /opt/tplink/EAPController/bin/control.sh
```

```
30:JAVA_OPTS="-server -Xmx1024m -XX:+UseSerialGC ..."
```

The heap is capped at 1 GB, yet the process reached 3 GB. So about 2 GB was **off-heap**: metaspace,
direct (NIO/Netty) buffers, thread stacks and glibc malloc arenas. None of these are covered by `-Xmx`.

### 1.8 Is MongoDB the culprit?

```sh
pct exec <CT> -- sh -c 'for p in jsvc mongod; do echo $p $(ps -o rss= -C $p | sort -n | tail -1 | awk "{print int(\$1/1024)}")MB; done'
```

```
jsvc 1496MB
mongod 122MB
```

No. MongoDB stays around 120 MB. Swapping the database would not help: the memory goes to Java.

### 1.9 Container memory and swap limit

```sh
grep -E "memory|swap" /etc/pve/lxc/<CT>.conf
pct exec <CT> -- free -m
```

```
memory: 3072
swap: 256
               total        used        free
Mem:            3072        1233        1586
```

## 2. Fix: cap off-heap memory

The script below adds three limits to `control.sh`:

| Setting | Limits |
|---|---|
| `-XX:MaxMetaspaceSize=256m` | class metadata |
| `-XX:MaxDirectMemorySize=256m` | direct/NIO buffers |
| `MALLOC_ARENA_MAX=2` | glibc malloc arenas (the usual source of native growth in many-thread JVMs) |

### 2.1 Back up control.sh

```sh
pct exec <CT> -- cp /opt/tplink/EAPController/bin/control.sh /root/control.sh.pre-limits
```

### 2.2 Install the script

Copy [`scripts/omada-limits.sh`](scripts/omada-limits.sh) to `/root/omada-limits.sh` inside the container:

```sh
pct push <CT> scripts/omada-limits.sh /root/omada-limits.sh --perms 755
```

It is idempotent: it changes `control.sh` only if the limits are missing. If TP-Link changes the
format of the `JAVA_OPTS` line, it only writes a message and exits 0, so the controller still starts.

### 2.3 Re-apply on every start (survives upgrades)

An upgrade (`dpkg -i` of the new .deb) overwrites `control.sh`, but it does not touch files in
`/etc/systemd/system`. A systemd drop-in runs the script before every start:

```sh
pct exec <CT> -- mkdir -p /etc/systemd/system/tpeap.service.d
pct push <CT> systemd/limits.conf /etc/systemd/system/tpeap.service.d/limits.conf
pct exec <CT> -- systemctl daemon-reload
```

[`systemd/limits.conf`](systemd/limits.conf):

```ini
[Service]
ExecStartPre=/root/omada-limits.sh
```

### 2.4 Check that the script is idempotent

```sh
pct exec <CT> -- sh -c "/root/omada-limits.sh; /root/omada-limits.sh; diff /root/control.sh.pre-limits /opt/tplink/EAPController/bin/control.sh"
```

```
30c30,31
< JAVA_OPTS="-server -Xmx1024m -XX:+UseSerialGC ..."
---
> export MALLOC_ARENA_MAX=2
> JAVA_OPTS="-server -XX:MaxMetaspaceSize=256m -XX:MaxDirectMemorySize=256m -Xmx1024m -XX:+UseSerialGC ..."
```

Two runs, a single change.

### 2.5 Restart and wait for the API

```sh
pct exec <CT> -- systemctl restart tpeap
until curl -sk -m10 https://<controller-ip>:8043/api/info | grep -q omadacId; do sleep 10; done; echo omada-ok
```

The first minutes return `{"errorCode":-1611,"msg":"Omada Controller is starting up, please wait."}`.
The API is ready when the answer contains `omadacId`.

### 2.6 Check that the running JVM has the limits

```sh
pct exec <CT> -- sh -c 'for P in $(pgrep jsvc); do tr "\0" " " < /proc/$P/cmdline | grep -oE "MaxMetaspaceSize=[0-9a-z]+|MaxDirectMemorySize=[0-9a-z]+" | tr "\n" " "; tr "\0" "\n" < /proc/$P/environ | grep MALLOC; done'
```

```
MaxMetaspaceSize=256m MaxDirectMemorySize=256m MALLOC_ARENA_MAX=2
```

### 2.7 Result after 12 hours

```
Mem:  4096 total, 1621 used
jsvc 1496MB
mongod 122MB
no OOM kill in the kernel log
```

Java grew by about 0.1 GB in 12 hours. If yours keeps growing, also give the container more RAM
(`pct set <CT> --memory 4096`).

## 3. Watchdog: restart automatically, log for later

systemd does not restart a unit that ended with `oom-kill` (the controller init script is a
generated LSB unit with no `Restart=`). The watchdog checks the API every hour and restarts the
controller if it does not answer.

### 3.1 How it works

1. n8n calls `GET https://<controller-ip>:8043/api/info` every hour (3 tries, 30 s timeout).
2. If the answer has no `result.omadacId`, n8n connects over SSH to the Proxmox host.
3. The SSH key is restricted to a single command (`command="...",restrict`), so n8n never holds a
   root password and the key cannot do anything else.
4. The script restarts the service, waits for port 8043, and writes two lines with a memory snapshot
   to `/var/log/omada-watchdog.log`.

### 3.2 Install the restart script on the Proxmox host

```sh
mkdir -p /root/omada-watchdog
cp scripts/restart.sh /root/omada-watchdog/restart.sh
chmod 700 /root/omada-watchdog/restart.sh
```

Set the container id with `OMADA_CT` in the script (default 400).

### 3.3 Create a dedicated, restricted SSH key

```sh
ssh-keygen -t ed25519 -N "" -C n8n-omada-watchdog -f ./n8n_omada_watchdog
cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.bak
echo "command=\"/root/omada-watchdog/restart.sh\",restrict $(cat ./n8n_omada_watchdog.pub)" >> /root/.ssh/authorized_keys
```

On Proxmox, `/root/.ssh/authorized_keys` is a symlink to `/etc/pve/priv/authorized_keys`, which is fine.

### 3.4 Test the key without restarting

The word `test` only writes a log line:

```sh
ssh -i ./n8n_omada_watchdog root@<proxmox-host> test
tail -1 /var/log/omada-watchdog.log
```

```
TEST
2026-10-19 18:01:43 TEST (no restart): svc=active mem_used_mb=1378 java_rss_mb=1281 mongod_rss_mb=125 uptime=80979s
```

### 3.5 Test the format n8n sends

The n8n SSH node sends `cd <dir>`, a newline, then the command. The script keeps only the last line,
so test that format too. Without this, `test` was not recognised and the controller was restarted:

```sh
ssh -i ./n8n_omada_watchdog root@<proxmox-host> "$(printf 'cd /\ntest')"
ssh -i ./n8n_omada_watchdog root@<proxmox-host> "cd / && test"
```

```
TEST
TEST
```

### 3.6 Import the workflow in n8n

1. Credentials → New → **SSH Private Key**: host = Proxmox host, user `root`, key = `n8n_omada_watchdog`.
2. Workflows → Import from file → [`n8n/omada-watchdog.json`](n8n/omada-watchdog.json).
3. In **Check controller** set the URL; in **Restart Omada** select the credential.
4. Optional: set an error workflow in the workflow settings so a failed run alerts you.
5. Activate.

### 3.7 Example log after a restart

```
2026-10-19 18:19:07 RESTART reason="n8n errore timeout of 30000ms exceeded" before: svc=active mem_used_mb=1495 java_rss_mb=1393 mongod_rss_mb=125 uptime=82024s  oom_kills_2h=0
2026-10-19 18:20:03 RESULT OK after 0s: svc=active mem_used_mb=1270 java_rss_mb=1174 mongod_rss_mb=125 uptime=82080s
```

This one was a false alarm: the check ran while the controller was still starting after a manual
restart. Avoid restarting by hand near minute 17, or skip the check while
`systemctl show tpeap -p ActiveEnterTimestamp` is less than 5 minutes old.

### 3.8 Read the log later

```sh
grep -E "RESTART|RESULT" /var/log/omada-watchdog.log
```

`java_rss_mb` growing between restarts means a slow leak. `oom_kills_2h` above 0 means the kernel
killed it again.

## Files

| Path | Where it goes |
|---|---|
| `scripts/omada-limits.sh` | `/root/omada-limits.sh` in the controller container |
| `systemd/limits.conf` | `/etc/systemd/system/tpeap.service.d/limits.conf` in the container |
| `scripts/restart.sh` | `/root/omada-watchdog/restart.sh` on the Proxmox host |
| `n8n/omada-watchdog.json` | imported in n8n |

## Rollback

```sh
pct exec <CT> -- rm /etc/systemd/system/tpeap.service.d/limits.conf
pct exec <CT> -- systemctl daemon-reload
pct exec <CT> -- cp /root/control.sh.pre-limits /opt/tplink/EAPController/bin/control.sh
pct exec <CT> -- systemctl restart tpeap
```

Remove the `n8n-omada-watchdog` line from `authorized_keys` and deactivate the workflow.

## License

MIT

---

Made with love ❤️ - [DLLFPP](https://buymeacoffee.com/dllfpp)
