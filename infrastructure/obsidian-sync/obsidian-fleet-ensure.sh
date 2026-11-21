#!/bin/bash
# 800802, every 30 min: keep Obsidian running on every Sync-only computer and
# alert when one falls behind. Offline machines are skipped silently and get
# caught up on the first run after they come back.
#   - reachable + Obsidian not running  -> start it (lag check waits a round)
#   - reachable + running + heartbeat lag > LAG_ALERT_MIN -> #admin alert
# Heartbeat: 06_Metadata/sync-heartbeat.md, stamped on 800801 every 15 min.
set -uo pipefail
LAG_ALERT_MIN=${LAG_ALERT_MIN:-120}
DRY=${DRY:-0}
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8)
# id | ssh host | os | vault path
NODES=(
  "800803|mac|mac|ObsidianVault"
  "800804|air|mac|ObsidianVault"
  "800805|dell|linux|Documents/Tyler"
)
hb() { grep -m1 '^heartbeat:' | awk '{print $2}'; }
epoch() { date -ud "$1" +%s 2>/dev/null || echo 0; }
bn() { if (( DRY )); then echo "[dry-run] boo-notify $*"; else boo-notify "$@" >/dev/null 2>&1 || true; fi; }

ref=$("${SSH[@]}" media 'cat ~/obsidian-vault/06_Metadata/sync-heartbeat.md' 2>/dev/null | hb)
[ -z "$ref" ] && { echo "no reference heartbeat on 800801; skipping lag checks"; }

for n in "${NODES[@]}"; do
  IFS='|' read -r id host os vault <<<"$n"
  if [ "$os" = mac ]; then
    remote='pgrep -x Obsidian >/dev/null && echo running || { open -g -a Obsidian && echo started; }'
  else
    # Launch inside the logged-in desktop session: GNOME exports its display
    # env into the systemd --user manager, so systemd-run inherits it.
    remote='if pgrep -x obsidian >/dev/null; then echo running;
      elif ! systemctl --user show-environment | grep -q "^WAYLAND_DISPLAY=\|^DISPLAY="; then echo nosession;
      else systemd-run --user --collect --unit=obsidian-sync-$(date +%s) /opt/obsidian/obsidian --no-sandbox >/dev/null 2>&1 && echo started || echo start-failed; fi'
  fi
  (( DRY )) && remote="${remote//open -g -a Obsidian/true}" && remote="${remote//systemd-run --user/true}"
  out=$("${SSH[@]}" "$host" "$remote; echo HB=\$(grep -m1 '^heartbeat:' ~/$vault/06_Metadata/sync-heartbeat.md 2>/dev/null | awk '{print \$2}')" 2>/dev/null) || { echo "$id: offline, skipped"; continue; }
  state=$(head -1 <<<"$out"); node_hb=$(grep -o 'HB=.*' <<<"$out" | cut -d= -f2)
  if [ "$state" != running ] || [ -z "$ref" ]; then echo "$id: $state"; continue; fi
  if [ -z "$node_hb" ]; then echo "$id: running, no heartbeat yet (still catching up?)"; node_hb="1970-01-01T00:00:00Z"; fi
  lag=$(( ( $(epoch "$ref") - $(epoch "$node_hb") ) / 60 ))
  [ "$node_hb" != 1970-01-01T00:00:00Z ] && echo "$id: running, lag ${lag}m"
  key="obsidian-sync-lag-$id"
  if [ "$lag" -gt "$LAG_ALERT_MIN" ]; then
    bn alert --key "$key" --subsystem obsidian-sync --host "$id" --status warn --min-failures 2 \
      --headline "Obsidian on $id is behind on sync" \
      --line "Device heartbeat=${node_hb/1970-01-01T00:00:00Z/none}" --line "800801 heartbeat=$ref" --line "Lag=${lag} min" \
      --next "Open Obsidian on $id and check Settings → Sync (paused? logged out?). Runbook: 01_Projects/media-server/obsidian-sync/README.md"
  else
    bn resolve --key "$key" --subsystem obsidian-sync --host "$id" --headline "Obsidian on $id caught up"
  fi
done
