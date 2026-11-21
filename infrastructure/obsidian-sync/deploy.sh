#!/bin/bash
# Deploy the Obsidian Sync tooling to 800801 (the git <-> Obsidian Sync bridge).
# Source of truth is this folder; ~/.local/bin on 800801 is a deployed copy.
set -euo pipefail
cd "$(dirname "$0")"
H=${1:-media}
ssh "$H" 'mkdir -p ~/.local/bin/obsidian-sync-old && for f in obsidian-healthcheck.sh obsidian-sync-audit.mjs obsidian-sync-probe.mjs obsidian-sync-notify.sh; do cp -p ~/.local/bin/$f ~/.local/bin/obsidian-sync-old/$f.prev 2>/dev/null || true; done'
scp -q obsidian-healthcheck.sh obsidian-sync-audit.mjs obsidian-sync-probe.mjs obsidian-sync-notify.sh obsidian-heartbeat.sh "$H":.local/bin/
scp -q systemd/* "$H":.config/systemd/user/
ssh "$H" 'chmod +x ~/.local/bin/obsidian-*.sh && systemctl --user daemon-reload && systemctl --user start obsidian-healthcheck.service && systemctl --user is-active obsidian.service'
