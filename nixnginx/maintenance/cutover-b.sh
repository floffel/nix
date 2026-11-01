#!/bin/bash
# Cut-over part B: activate the objectstore config, verify, reopen.
set -uo pipefail
LOG=/root/cutover-rebuild.log
step() { echo; echo "########## $* — $(date +%H:%M:%S) ##########"; }

step "6. nixos-rebuild switch (objectstore enabled)"
rm -f "$LOG"
pct push 104 /var/lib/nc-s3-migration/launch.sh /tmp/launch.sh >/dev/null 2>&1 || true
pct exec 104 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; bash /var/lib/nc-s3-migration/launch.sh nc-cutover-rebuild $LOG /root/do-switch.sh"
for i in $(seq 1 60); do
  sleep 15
  st=$(pct exec 104 -- /run/current-system/sw/bin/bash -lc "systemctl is-active nc-cutover-rebuild"; true)
  [ "$st" = "activating" ] || { echo "rebuild finished (state=$st) after $((i*15))s"; break; }
  echo "  ...building ($((i*15))s)"
done
pct exec 104 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; tail -6 $LOG"

step "7. verify the objectstore config is live"
pct exec 104 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; grep -c objectstore /var/lib/nextcloud-data/config/override.config.php; systemctl is-active phpfpm-nextcloud nextcloud-setup; nextcloud-occ config:system:get objectstore class 2>&1 | tail -2"

# If the rebuild did not land, the database is already remapped but Nextcloud
# is still running the local-storage config: reopening now would show users an
# empty Files app.  Keep the maintenance page up and hand over instead.
OBJ=$(pct exec 104 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; grep -c objectstore /var/lib/nextcloud-data/config/override.config.php" 2>/dev/null)
FPM=$(pct exec 104 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; systemctl is-active phpfpm-nextcloud" 2>/dev/null)
if [ "${OBJ:-0}" -lt 1 ] || [ "$FPM" != "active" ]; then
  echo "!! rebuild did not take effect (objectstore lines=${OBJ:-0}, phpfpm=$FPM)."
  echo "!! leaving maintenance mode ON so nobody sees an empty Files app."
  echo "!! rollback: /tmp/cutover-rollback.sh CONFIRM   (log: $LOG)"
  exit 1
fi

step "8. maintenance mode OFF"
pct exec 104 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; nextcloud-occ maintenance:mode --off; nextcloud-occ maintenance:mode"

step "9. read sampled files back through Nextcloud (expect object::user: ids)"
pct exec 104 -- /run/current-system/sw/bin/bash /var/lib/nc-s3-migration/nc-s3-readtest.sh 2>&1 | tail -22

step "10. status + recent errors"
pct exec 104 -- /run/current-system/sw/bin/bash -lc "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; nextcloud-occ status 2>&1 | head -8; echo ---log---; tail -c 3000 /var/lib/nextcloud-data/data/nextcloud.log 2>/dev/null | grep -oE '\"message\":\"[^\"]{0,160}' | tail -6"
echo
echo "PART B DONE at $(date +%H:%M:%S)"
