#!/bin/sh
# Off-heap memory limits for the Omada controller.
# Idempotent: run it as ExecStartPre of tpeap so it is re-applied on every start,
# including after an upgrade that overwrites control.sh.
F=/opt/tplink/EAPController/bin/control.sh
grep -q "^JAVA_OPTS=" $F || { echo "omada-limits: JAVA_OPTS not found in $F" >&2; exit 0; }
grep -q MaxMetaspaceSize $F || sed -i 's/^JAVA_OPTS="-server /JAVA_OPTS="-server -XX:MaxMetaspaceSize=256m -XX:MaxDirectMemorySize=256m /' $F
grep -q "^export MALLOC_ARENA_MAX" $F || sed -i '/^JAVA_OPTS=/i export MALLOC_ARENA_MAX=2' $F
exit 0
